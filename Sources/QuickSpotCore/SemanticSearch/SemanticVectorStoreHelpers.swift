import Accelerate
import Foundation
import SQLite3

let semanticSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension SemanticVectorStore {
    func migrateSchemaIfNeeded() {
        guard db != nil else { return }
        if !hasColumn(table: "image_embeddings", column: "status") {
            exec("ALTER TABLE image_embeddings ADD COLUMN status INTEGER NOT NULL DEFAULT 1;")
        }
        if !hasColumn(table: "image_embeddings", column: "retry_count") {
            exec("ALTER TABLE image_embeddings ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0;")
        }
        exec("CREATE INDEX IF NOT EXISTS idx_image_embeddings_model_status ON image_embeddings(model_id, status);")
    }

    public func recordFailures(
        _ items: [(path: String, name: String, mtime: Double, size: Int64)],
        modelID: String
    ) {
        guard !items.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard let db else { return }
        guard exec("BEGIN IMMEDIATE;") else { return }

        var touchedLoadedMatrix = false
        for item in items {
            let existing = lookupExistingLocked(path: item.path)
            let sameVersion = existing.map {
                $0.modelID == modelID && abs($0.mtime - item.mtime) <= 0.001 && $0.size == item.size
            } ?? false
            let nextRetries = sameVersion ? ((existing?.retryCount ?? 0) + 1) : 1

            let sql = """
            INSERT INTO image_embeddings (path, name, mtime, size, model_id, dim, vector, status, retry_count)
            VALUES (?, ?, ?, ?, ?, 0, zeroblob(0), ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                name = excluded.name,
                mtime = excluded.mtime,
                size = excluded.size,
                model_id = excluded.model_id,
                dim = 0,
                vector = zeroblob(0),
                status = excluded.status,
                retry_count = excluded.retry_count;
            """
            _ = runStatement(sql) { stmt in
                bindText(stmt, 1, item.path)
                bindText(stmt, 2, item.name)
                sqlite3_bind_double(stmt, 3, item.mtime)
                sqlite3_bind_int64(stmt, 4, item.size)
                bindText(stmt, 5, modelID)
                sqlite3_bind_int64(stmt, 6, Int64(Self.statusFailed))
                sqlite3_bind_int64(stmt, 7, Int64(nextRetries))
            }
            if pathToRowIndex[item.path] != nil {
                touchedLoadedMatrix = true
            }
        }
        _ = db // keep explicit borrow clarity
        exec("COMMIT;")
        if touchedLoadedMatrix {
            matrixDirty = true
            hubnessDirty = true
        }
    }

    public func existingEntries() -> [String: SemanticStoreEntry] {
        lock.lock(); defer { lock.unlock() }
        var map: [String: SemanticStoreEntry] = [:]
        var stmt: OpaquePointer?
        let sql = "SELECT path, mtime, size, model_id, status, retry_count FROM image_embeddings;"
        guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return map }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            map[columnString(stmt, 0)] = SemanticStoreEntry(
                mtime: sqlite3_column_double(stmt, 1),
                size: sqlite3_column_int64(stmt, 2),
                modelID: columnString(stmt, 3),
                status: Int(sqlite3_column_int64(stmt, 4)),
                retryCount: Int(sqlite3_column_int64(stmt, 5))
            )
        }
        return map
    }

    /// Targeted lookup for incremental watcher updates without loading all stored paths into memory.
    public func existingEntries(forPaths paths: [String]) -> [String: SemanticStoreEntry] {
        guard !paths.isEmpty else { return [:] }
        lock.lock(); defer { lock.unlock() }
        guard let db else { return [:] }

        var map: [String: SemanticStoreEntry] = [:]
        map.reserveCapacity(paths.count)
        let chunkSize = 200
        var offset = 0
        while offset < paths.count {
            let end = min(offset + chunkSize, paths.count)
            let slice = paths[offset..<end]
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            let sql = "SELECT path, mtime, size, model_id, status, retry_count FROM image_embeddings WHERE path IN (\(placeholders));"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                for (idx, path) in slice.enumerated() {
                    bindText(stmt, Int32(idx + 1), path)
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    map[columnString(stmt, 0)] = SemanticStoreEntry(
                        mtime: sqlite3_column_double(stmt, 1),
                        size: sqlite3_column_int64(stmt, 2),
                        modelID: columnString(stmt, 3),
                        status: Int(sqlite3_column_int64(stmt, 4)),
                        retryCount: Int(sqlite3_column_int64(stmt, 5))
                    )
                }
                sqlite3_finalize(stmt)
            }
            offset = end
        }
        return map
    }

    public func delete(paths: [String]) {
        guard !paths.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard exec("BEGIN IMMEDIATE;") else { return }
        for path in paths {
            runStatement("DELETE FROM image_embeddings WHERE path = ?;") { bindText($0, 1, path) }
        }
        exec("COMMIT;")
        matrixDirty = true
        hubnessDirty = true
    }

    /// Immediately removes all embeddings for a removed or excluded folder regardless of battery/indexing state.
    public func deleteUnderFolder(_ folderPath: String) {
        let std = (folderPath as NSString).standardizingPath
        let clean = std.count > 1 && std.hasSuffix("/") ? String(std.dropLast()) : std
        guard !clean.isEmpty else { return }

        let escaped = clean
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let prefixPattern = clean == "/" ? "/%" : "\(escaped)/%"

        lock.lock(); defer { lock.unlock() }
        guard let db else { return }
        guard exec("BEGIN IMMEDIATE;") else { return }
        let ok = runStatement("DELETE FROM image_embeddings WHERE path = ? OR path LIKE ? ESCAPE '\\';") { stmt in
            bindText(stmt, 1, clean)
            bindText(stmt, 2, prefixPattern)
        }
        let changes = sqlite3_changes(db)
        exec(ok ? "COMMIT;" : "ROLLBACK;")
        if ok && changes > 0 {
            matrixDirty = true
            hubnessDirty = true
        }
    }

    public func deleteMissing(keeping paths: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, "SELECT id, path FROM image_embeddings;", -1, &stmt, nil) == SQLITE_OK else { return }
        var staleIDs: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if !paths.contains(columnString(stmt, 1)) {
                staleIDs.append(sqlite3_column_int64(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        guard !staleIDs.isEmpty else { return }
        guard exec("BEGIN IMMEDIATE;") else { return }
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM image_embeddings WHERE id = ?;", -1, &delStmt, nil) == SQLITE_OK {
            for id in staleIDs {
                sqlite3_reset(delStmt)
                sqlite3_bind_int64(delStmt, 1, id)
                _ = sqlite3_step(delStmt)
            }
            sqlite3_finalize(delStmt)
        }
        exec("COMMIT;")
        matrixDirty = true
        hubnessDirty = true
    }

    public func clearAll() {
        lock.lock(); defer { lock.unlock() }
        guard exec("BEGIN IMMEDIATE;") else { return }
        let ok = exec("DELETE FROM image_embeddings;")
        exec(ok ? "COMMIT;" : "ROLLBACK;")
        matrixData.removeAll(keepingCapacity: false)
        hubnessAdjustment.removeAll(keepingCapacity: false)
        rowMeta.removeAll(keepingCapacity: false)
        pathToRowIndex.removeAll(keepingCapacity: false)
        matrixDirty = true
        hubnessDirty = true
    }

    public func count(forModelID modelID: String? = nil) -> Int {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        let sql = modelID == nil
            ? "SELECT COUNT(*) FROM image_embeddings WHERE status = 1;"
            : "SELECT COUNT(*) FROM image_embeddings WHERE model_id = ? AND status = 1;"
        guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if let modelID { bindText(stmt, 1, modelID) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// Returns the stored normalized embedding vector for `path`, serving directly from the in-memory matrix when loaded.
    public func vector(forPath path: String, modelID: String, dimension: Int) -> [Float]? {
        guard dimension > 0 else { return nil }
        let stdPath = (path as NSString).standardizingPath
        lock.lock(); defer { lock.unlock() }

        if !matrixDirty, matrixModelID == modelID, matrixDimension == dimension,
           let idx = pathToRowIndex[stdPath] {
            let start = idx * dimension
            let end = start + dimension
            if end <= matrixData.count {
                return Array(matrixData[start..<end])
            }
        }

        var stmt: OpaquePointer?
        let sql = "SELECT vector FROM image_embeddings WHERE path = ? AND model_id = ? AND dim = ? AND status = 1 LIMIT 1;"
        guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, stdPath)
        bindText(stmt, 2, modelID)
        sqlite3_bind_int64(stmt, 3, Int64(dimension))

        let expectedBytes = dimension * MemoryLayout<Float>.stride
        guard sqlite3_step(stmt) == SQLITE_ROW,
              Int(sqlite3_column_bytes(stmt, 0)) == expectedBytes,
              let blob = sqlite3_column_blob(stmt, 0) else {
            return nil
        }
        var result = [Float](repeating: 0, count: dimension)
        result.withUnsafeMutableBytes { dst in
            guard let base = dst.baseAddress else { return }
            memcpy(base, blob, expectedBytes)
        }
        return result
    }

    /// Returns a lock-free snapshot of the normalized Float32 matrix for off-lock pairwise analysis (e.g. near-duplicate clustering).
    func matrixSnapshot(
        modelID: String,
        dimension: Int
    ) -> (rows: [(path: String, name: String, mtime: Double)], data: [Float], dimension: Int) {
        guard dimension > 0 else { return ([], [], 0) }
        lock.lock(); defer { lock.unlock() }
        reloadMatrixIfNeeded(modelID: modelID, dimension: dimension)
        guard !rowMeta.isEmpty, matrixDimension == dimension else { return ([], [], 0) }
        let rows = rowMeta.map { ($0.path, $0.name, $0.mtime) }
        return (rows, matrixData, matrixDimension)
    }

    func applyIncrementalMatrixUpsertsLocked(_ items: [SemanticVectorUpsert]) {
        guard !items.isEmpty else { return }
        guard !matrixDirty, !matrixModelID.isEmpty, matrixDimension > 0 else {
            matrixDirty = true
            hubnessDirty = true
            return
        }

        for item in items {
            guard item.modelID == matrixModelID, item.vector.count == matrixDimension else {
                matrixDirty = true
                hubnessDirty = true
                return
            }
            let meta = RowMeta(path: item.path, name: item.name, mtime: item.mtime)
            if let existingIdx = pathToRowIndex[item.path] {
                rowMeta[existingIdx] = meta
                let offset = existingIdx * matrixDimension
                for d in 0..<matrixDimension {
                    matrixData[offset + d] = item.vector[d]
                }
            } else {
                let newIdx = rowMeta.count
                rowMeta.append(meta)
                pathToRowIndex[item.path] = newIdx
                matrixData.append(contentsOf: item.vector)
            }
        }
        hubnessDirty = true
    }

    func reloadMatrixIfNeeded(modelID: String, dimension: Int) {
        guard matrixDirty || matrixModelID != modelID || matrixDimension != dimension else { return }
        matrixData.removeAll(keepingCapacity: true)
        hubnessAdjustment.removeAll(keepingCapacity: true)
        rowMeta.removeAll(keepingCapacity: true)
        pathToRowIndex.removeAll(keepingCapacity: true)
        matrixModelID = modelID
        matrixDimension = dimension

        var stmt: OpaquePointer?
        let sql = "SELECT path, name, mtime, vector FROM image_embeddings WHERE model_id = ? AND dim = ? AND status = 1;"
        guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            matrixDirty = false
            hubnessDirty = false
            return
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, modelID)
        sqlite3_bind_int64(stmt, 2, Int64(dimension))

        let expectedBytes = dimension * MemoryLayout<Float>.stride
        while sqlite3_step(stmt) == SQLITE_ROW {
            let byteCount = Int(sqlite3_column_bytes(stmt, 3))
            guard byteCount == expectedBytes, let blob = sqlite3_column_blob(stmt, 3) else { continue }
            let path = columnString(stmt, 0)
            let name = columnString(stmt, 1)
            let mtime = sqlite3_column_double(stmt, 2)
            let rowIdx = rowMeta.count
            rowMeta.append(RowMeta(path: path, name: name, mtime: mtime))
            pathToRowIndex[path] = rowIdx

            let start = matrixData.count
            matrixData.append(contentsOf: repeatElement(Float(0), count: dimension))
            matrixData.withUnsafeMutableBytes { dst in
                guard let base = dst.baseAddress else { return }
                memcpy(base.advanced(by: start * MemoryLayout<Float>.stride), blob, expectedBytes)
            }
        }
        computeHubnessAdjustmentIfNeeded()
        matrixDirty = false
        hubnessDirty = false
    }

    func computeHubnessAdjustmentIfNeeded() {
        let rowCount = rowMeta.count
        let dim = matrixDimension
        guard rowCount >= Self.minCorpusForHubness, dim > 0 else {
            hubnessAdjustment = []
            return
        }

        var centroid = [Float](repeating: 0, count: dim)
        matrixData.withUnsafeBufferPointer { mBuf in
            guard let mPtr = mBuf.baseAddress else { return }
            centroid.withUnsafeMutableBufferPointer { cBuf in
                guard let cPtr = cBuf.baseAddress else { return }
                for row in 0..<rowCount {
                    vDSP_vadd(cPtr, 1, mPtr.advanced(by: row * dim), 1, cPtr, 1, vDSP_Length(dim))
                }
            }
        }

        var normSq: Float = 0
        vDSP_dotpr(centroid, 1, centroid, 1, &normSq, vDSP_Length(dim))
        let norm = sqrt(normSq)
        guard norm > 1e-6 else {
            hubnessAdjustment = []
            return
        }
        var invNorm = 1.0 / norm
        vDSP_vsmul(centroid, 1, &invNorm, &centroid, 1, vDSP_Length(dim))

        var hubness = [Float](repeating: 0, count: rowCount)
        matrixData.withUnsafeBufferPointer { mBuf in
            centroid.withUnsafeBufferPointer { cBuf in
                hubness.withUnsafeMutableBufferPointer { hBuf in
                    guard let mPtr = mBuf.baseAddress,
                          let cPtr = cBuf.baseAddress,
                          let hPtr = hBuf.baseAddress else { return }
                    vDSP_mmul(mPtr, 1, cPtr, 1, hPtr, 1, vDSP_Length(rowCount), 1, vDSP_Length(dim))
                }
            }
        }

        var meanHubness: Float = 0
        vDSP_meanv(hubness, 1, &meanHubness, vDSP_Length(rowCount))
        hubnessAdjustment = hubness.map { -Self.hubnessAlpha * ($0 - meanHubness) }
    }

    private func lookupExistingLocked(path: String) -> SemanticStoreEntry? {
        var stmt: OpaquePointer?
        let sql = "SELECT mtime, size, model_id, status, retry_count FROM image_embeddings WHERE path = ?;"
        guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, path)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return SemanticStoreEntry(
            mtime: sqlite3_column_double(stmt, 0),
            size: sqlite3_column_int64(stmt, 1),
            modelID: columnString(stmt, 2),
            status: Int(sqlite3_column_int64(stmt, 3)),
            retryCount: Int(sqlite3_column_int64(stmt, 4))
        )
    }

    private func hasColumn(table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if columnString(stmt, 1) == column { return true }
        }
        return false
    }

    @discardableResult
    func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    @discardableResult
    func runStatement(_ sql: String, bind: (OpaquePointer?) -> Void) -> Bool {
        var stmt: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(stmt, idx, value, -1, semanticSQLiteTransient)
    }

    func columnString(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        sqlite3_column_text(stmt, idx).map { String(cString: $0) } ?? ""
    }
}
