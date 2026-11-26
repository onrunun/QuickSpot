import Accelerate
import Foundation
import os
import SQLite3

/// SQLite-persisted chunk vector store backing semantic PDF and OCR text search with per-document max-pooling via `vDSP_mmul`.
public final class SemanticDocumentStore: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.quickspot.core", category: "SemanticDocumentStore")

    public static let statusIndexed = 1
    public static let statusFailed = 2
    public static let maxFailureRetries = 2

    private struct ChunkRowMeta {
        let path: String
        let name: String
        let kind: OCRDocumentKind
        let excerpt: String
        let mtime: Double
    }

    private let lock = NSLock()
    private var db: OpaquePointer?

    private var matrixDirty = true
    private var matrixModelID = ""
    private var matrixDimension = 0
    private var matrixData: [Float] = []
    private var hubnessAdjustment: [Float] = []
    private var rowMeta: [ChunkRowMeta] = []

    /// Mild centroid hubness damping applied on corpora with >= 20 chunks so boilerplate docs do not dominate unrelated queries.
    private static let hubnessAlpha: Float = 0.35
    private static let minChunksForHubness = 20

    public init(databaseURL: URL? = nil) {
        let targetURL = databaseURL ?? Self.defaultDatabaseURL()
        let isMemory = targetURL.path == ":memory:"
        if !isMemory {
            try? FileManager.default.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        var handle: OpaquePointer?
        let path = isMemory ? ":memory:" : targetURL.path
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let handle {
            db = handle
            sqlite3_busy_timeout(handle, 3000)
            if !isMemory { exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;") }
            exec("""
            CREATE TABLE IF NOT EXISTS doc_chunks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                path TEXT NOT NULL,
                name TEXT NOT NULL,
                kind INTEGER NOT NULL DEFAULT 1,
                chunk_index INTEGER NOT NULL,
                excerpt TEXT NOT NULL,
                mtime REAL NOT NULL,
                size INTEGER NOT NULL,
                model_id TEXT NOT NULL,
                dim INTEGER NOT NULL,
                vector BLOB NOT NULL,
                UNIQUE(path, chunk_index)
            );
            CREATE TABLE IF NOT EXISTS doc_state (
                path TEXT PRIMARY KEY,
                mtime REAL NOT NULL,
                size INTEGER NOT NULL,
                model_id TEXT NOT NULL,
                status INTEGER NOT NULL DEFAULT 1,
                retry_count INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_doc_chunks_model_kind ON doc_chunks(model_id, kind);
            CREATE INDEX IF NOT EXISTS idx_doc_chunks_path ON doc_chunks(path);
            """)
        } else {
            Self.logger.error("Failed to open semantic document SQLite database")
            sqlite3_close(handle)
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    public static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("QuickSpot/document-embeddings.sqlite")
    }

    public func upsertDocumentChunks(
        path: String,
        name: String,
        kind: OCRDocumentKind,
        mtime: Double,
        size: Int64,
        modelID: String,
        chunks: [(chunk: SemanticTextChunk, vector: [Float])]
    ) {
        let valid = chunks.filter { !$0.vector.isEmpty }
        guard !valid.isEmpty else { return }

        lock.lock(); defer { lock.unlock() }
        guard let db else { return }
        guard exec("BEGIN IMMEDIATE;") else { return }

        let deletedOld = runStatement("DELETE FROM doc_chunks WHERE path = ?;") { bindText($0, 1, path) }
        guard deletedOld else { exec("ROLLBACK;"); return }

        let insertSQL = """
        INSERT INTO doc_chunks (path, name, kind, chunk_index, excerpt, mtime, size, model_id, dim, vector)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            exec("ROLLBACK;")
            return
        }
        var ok = true
        for (chunk, vector) in valid {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, path)
            bindText(stmt, 2, name)
            sqlite3_bind_int64(stmt, 3, Int64(kind.rawValue))
            sqlite3_bind_int64(stmt, 4, Int64(chunk.index))
            bindText(stmt, 5, chunk.excerpt)
            sqlite3_bind_double(stmt, 6, mtime)
            sqlite3_bind_int64(stmt, 7, size)
            bindText(stmt, 8, modelID)
            sqlite3_bind_int64(stmt, 9, Int64(vector.count))
            _ = vector.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 10, raw.baseAddress, Int32(raw.count), semanticSQLiteTransient)
            }
            if sqlite3_step(stmt) != SQLITE_DONE { ok = false; break }
        }
        sqlite3_finalize(stmt)

        let stateSQL = """
        INSERT INTO doc_state (path, mtime, size, model_id, status, retry_count)
        VALUES (?, ?, ?, ?, 1, 0)
        ON CONFLICT(path) DO UPDATE SET
            mtime = excluded.mtime, size = excluded.size, model_id = excluded.model_id, status = 1, retry_count = 0;
        """
        let stateOK = ok && runStatement(stateSQL) { s in
            bindText(s, 1, path)
            sqlite3_bind_double(s, 2, mtime)
            sqlite3_bind_int64(s, 3, size)
            bindText(s, 4, modelID)
        }
        exec(stateOK ? "COMMIT;" : "ROLLBACK;")
        if stateOK { matrixDirty = true }
    }

    public func recordFailure(path: String, mtime: Double, size: Int64, modelID: String) {
        lock.lock(); defer { lock.unlock() }
        guard db != nil, exec("BEGIN IMMEDIATE;") else { return }
        let existing = lookupStateLocked(path: path)
        let sameVersion = existing.map {
            $0.modelID == modelID && abs($0.mtime - mtime) <= 0.001 && $0.size == size
        } ?? false
        let nextRetries = sameVersion ? ((existing?.retryCount ?? 0) + 1) : 1
        _ = runStatement("DELETE FROM doc_chunks WHERE path = ?;") { bindText($0, 1, path) }
        let ok = runStatement("""
            INSERT INTO doc_state (path, mtime, size, model_id, status, retry_count)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                mtime = excluded.mtime, size = excluded.size, model_id = excluded.model_id,
                status = excluded.status, retry_count = excluded.retry_count;
            """) { s in
            bindText(s, 1, path)
            sqlite3_bind_double(s, 2, mtime)
            sqlite3_bind_int64(s, 3, size)
            bindText(s, 4, modelID)
            sqlite3_bind_int64(s, 5, Int64(Self.statusFailed))
            sqlite3_bind_int64(s, 6, Int64(nextRetries))
        }
        exec(ok ? "COMMIT;" : "ROLLBACK;")
        if ok { matrixDirty = true }
    }

    public func existingStates() -> [String: SemanticStoreEntry] {
        lock.lock(); defer { lock.unlock() }
        var map: [String: SemanticStoreEntry] = [:]
        var stmt: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, "SELECT path, mtime, size, model_id, status, retry_count FROM doc_state;", -1, &stmt, nil) == SQLITE_OK else {
            return map
        }
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

    public func delete(paths: [String]) {
        guard !paths.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard exec("BEGIN IMMEDIATE;") else { return }
        for path in paths {
            _ = runStatement("DELETE FROM doc_chunks WHERE path = ?;") { bindText($0, 1, path) }
            _ = runStatement("DELETE FROM doc_state WHERE path = ?;") { bindText($0, 1, path) }
        }
        exec("COMMIT;")
        matrixDirty = true
    }

    public func deleteUnderFolder(_ folderPath: String) {
        let std = (folderPath as NSString).standardizingPath
        let clean = std.count > 1 && std.hasSuffix("/") ? String(std.dropLast()) : std
        guard !clean.isEmpty else { return }
        let escaped = clean
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = clean == "/" ? "/%" : "\(escaped)/%"

        lock.lock(); defer { lock.unlock() }
        guard exec("BEGIN IMMEDIATE;") else { return }
        let ok1 = runStatement("DELETE FROM doc_chunks WHERE path = ? OR path LIKE ? ESCAPE '\\';") {
            bindText($0, 1, clean); bindText($0, 2, pattern)
        }
        let ok2 = runStatement("DELETE FROM doc_state WHERE path = ? OR path LIKE ? ESCAPE '\\';") {
            bindText($0, 1, clean); bindText($0, 2, pattern)
        }
        exec((ok1 && ok2) ? "COMMIT;" : "ROLLBACK;")
        if ok1 && ok2 { matrixDirty = true }
    }

    public func deleteMissing(keeping paths: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, "SELECT path FROM doc_state;", -1, &stmt, nil) == SQLITE_OK else { return }
        var stale: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let p = columnString(stmt, 0)
            if !paths.contains(p) { stale.append(p) }
        }
        sqlite3_finalize(stmt)
        guard !stale.isEmpty else { return }
        guard exec("BEGIN IMMEDIATE;") else { return }
        for path in stale {
            _ = runStatement("DELETE FROM doc_chunks WHERE path = ?;") { bindText($0, 1, path) }
            _ = runStatement("DELETE FROM doc_state WHERE path = ?;") { bindText($0, 1, path) }
        }
        exec("COMMIT;")
        matrixDirty = true
    }

    public func clearAll() {
        lock.lock(); defer { lock.unlock() }
        guard exec("BEGIN IMMEDIATE;") else { return }
        let ok = exec("DELETE FROM doc_chunks; DELETE FROM doc_state;")
        exec(ok ? "COMMIT;" : "ROLLBACK;")
        matrixData.removeAll(keepingCapacity: false)
        rowMeta.removeAll(keepingCapacity: false)
        matrixDirty = true
    }

    public func documentCount(forModelID modelID: String? = nil) -> Int {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        let sql = modelID == nil
            ? "SELECT COUNT(*) FROM doc_state WHERE status = 1;"
            : "SELECT COUNT(*) FROM doc_state WHERE model_id = ? AND status = 1;"
        guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if let modelID { bindText(stmt, 1, modelID) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// Computes an L2-normalized centroid across all stored chunk vectors for `path` so document-to-document similarity reflects overall topic.
    public func centroidVector(forPath path: String, modelID: String, dimension: Int) -> [Float]? {
        guard dimension > 0 else { return nil }
        let stdPath = (path as NSString).standardizingPath
        lock.lock(); defer { lock.unlock() }

        var sum = [Float](repeating: 0, count: dimension)
        var chunkCount = 0

        if !matrixDirty, matrixModelID == modelID, matrixDimension == dimension {
            matrixData.withUnsafeBufferPointer { mBuf in
                guard let mPtr = mBuf.baseAddress else { return }
                sum.withUnsafeMutableBufferPointer { sBuf in
                    guard let sPtr = sBuf.baseAddress else { return }
                    for i in 0..<rowMeta.count where rowMeta[i].path == stdPath {
                        vDSP_vadd(sPtr, 1, mPtr.advanced(by: i * dimension), 1, sPtr, 1, vDSP_Length(dimension))
                        chunkCount += 1
                    }
                }
            }
        } else {
            var stmt: OpaquePointer?
            let sql = "SELECT vector FROM doc_chunks WHERE path = ? AND model_id = ? AND dim = ? ORDER BY chunk_index ASC;"
            guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, stdPath)
            bindText(stmt, 2, modelID)
            sqlite3_bind_int64(stmt, 3, Int64(dimension))

            let expectedBytes = dimension * MemoryLayout<Float>.stride
            var scratch = [Float](repeating: 0, count: dimension)
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard Int(sqlite3_column_bytes(stmt, 0)) == expectedBytes,
                      let blob = sqlite3_column_blob(stmt, 0) else { continue }
                scratch.withUnsafeMutableBytes { dst in
                    guard let base = dst.baseAddress else { return }
                    memcpy(base, blob, expectedBytes)
                }
                vDSP_vadd(sum, 1, scratch, 1, &sum, 1, vDSP_Length(dimension))
                chunkCount += 1
            }
        }

        guard chunkCount > 0 else { return nil }
        var normSq: Float = 0
        vDSP_dotpr(sum, 1, sum, 1, &normSq, vDSP_Length(dimension))
        let norm = sqrt(normSq)
        guard norm > 1e-6 else { return nil }
        var invNorm = 1.0 / norm
        vDSP_vsmul(sum, 1, &invNorm, &sum, 1, vDSP_Length(dimension))
        return sum
    }

    /// Searches document chunks with `vDSP_mmul` and max-pools by document path, returning each document's best-matching passage.
    public func searchWithStats(
        queryVectors: [[Float]],
        negativeVectors: [[Float]] = [],
        modelID: String,
        kind: OCRDocumentKind? = nil,
        limit: Int = 10,
        minSimilarity: Float = -1.0,
        excludePath: String? = nil,
        applyHubness: Bool = true
    ) -> SemanticDocumentSearchResult {
        guard let first = queryVectors.first, !first.isEmpty, limit > 0 else {
            return SemanticDocumentSearchResult(hits: [], documentCount: 0, mean: 0, stdDev: 0)
        }
        let dim = first.count
        guard queryVectors.allSatisfy({ $0.count == dim }) else {
            return SemanticDocumentSearchResult(hits: [], documentCount: 0, mean: 0, stdDev: 0)
        }
        let validNegatives = negativeVectors.filter { $0.count == dim }

        lock.lock(); defer { lock.unlock() }
        reloadMatrixIfNeeded(modelID: modelID, dimension: dim)

        let rowCount = rowMeta.count
        guard rowCount > 0, matrixDimension == dim else {
            return SemanticDocumentSearchResult(hits: [], documentCount: 0, mean: 0, stdDev: 0)
        }

        var scores = [Float](repeating: -Float.greatestFiniteMagnitude, count: rowCount)
        var scratch = [Float](repeating: 0, count: rowCount)

        for queryVector in queryVectors {
            matrixData.withUnsafeBufferPointer { mBuf in
                queryVector.withUnsafeBufferPointer { qBuf in
                    scratch.withUnsafeMutableBufferPointer { sBuf in
                        guard let mPtr = mBuf.baseAddress,
                              let qPtr = qBuf.baseAddress,
                              let sPtr = sBuf.baseAddress else { return }
                        vDSP_mmul(mPtr, 1, qPtr, 1, sPtr, 1, vDSP_Length(rowCount), 1, vDSP_Length(dim))
                    }
                }
            }
            if queryVectors.count == 1 {
                scores = scratch
            } else {
                vDSP_vmax(scores, 1, scratch, 1, &scores, 1, vDSP_Length(rowCount))
            }
        }

        if applyHubness && hubnessAdjustment.count == rowCount {
            vDSP_vadd(scores, 1, hubnessAdjustment, 1, &scores, 1, vDSP_Length(rowCount))
        }

        if !validNegatives.isEmpty {
            var negScores = [Float](repeating: -Float.greatestFiniteMagnitude, count: rowCount)
            for negVector in validNegatives {
                matrixData.withUnsafeBufferPointer { mBuf in
                    negVector.withUnsafeBufferPointer { qBuf in
                        scratch.withUnsafeMutableBufferPointer { sBuf in
                            guard let mPtr = mBuf.baseAddress,
                                  let qPtr = qBuf.baseAddress,
                                  let sPtr = sBuf.baseAddress else { return }
                            vDSP_mmul(mPtr, 1, qPtr, 1, sPtr, 1, vDSP_Length(rowCount), 1, vDSP_Length(dim))
                        }
                    }
                }
                if validNegatives.count == 1 {
                    negScores = scratch
                } else {
                    vDSP_vmax(negScores, 1, scratch, 1, &negScores, 1, vDSP_Length(rowCount))
                }
            }
            if applyHubness && hubnessAdjustment.count == rowCount {
                vDSP_vadd(negScores, 1, hubnessAdjustment, 1, &negScores, 1, vDSP_Length(rowCount))
            }
            var negMean: Float = 0
            vDSP_meanv(negScores, 1, &negMean, vDSP_Length(rowCount))
            let baseline = max(Float(0), negMean)
            for i in 0..<rowCount {
                let pos = scores[i]
                let neg = negScores[i]
                guard pos.isFinite, neg.isFinite else { continue }
                let excess = max(Float(0), neg - baseline)
                var adjusted = pos - 0.55 * excess
                if neg >= pos - 0.01 && excess > 0.05 {
                    adjusted -= 0.08
                }
                scores[i] = adjusted
            }
        }

        let excludedPath = excludePath.map { ($0 as NSString).standardizingPath }

        // Max-pool chunk scores into one best passage per document path (optionally filtered by kind and excluding self).
        var bestByPath: [String: (idx: Int, score: Float)] = [:]
        for i in 0..<rowCount {
            let meta = rowMeta[i]
            if let excludedPath, meta.path == excludedPath { continue }
            if let kind, meta.kind != kind { continue }
            let s = scores[i]
            guard s.isFinite else { continue }
            if let existing = bestByPath[meta.path] {
                if s > existing.score { bestByPath[meta.path] = (i, s) }
            } else {
                bestByPath[meta.path] = (i, s)
            }
        }

        let docEntries = Array(bestByPath.values)
        guard !docEntries.isEmpty else {
            return SemanticDocumentSearchResult(hits: [], documentCount: 0, mean: 0, stdDev: 0)
        }

        let docScores = docEntries.map(\.score)
        var mean: Float = 0
        var stdDev: Float = 0
        if docScores.count >= 2 {
            vDSP_meanv(docScores, 1, &mean, vDSP_Length(docScores.count))
            var sumSq: Float = 0
            for s in docScores {
                let d = s - mean
                sumSq += d * d
            }
            stdDev = sqrt(sumSq / Float(docScores.count))
        } else {
            mean = docScores[0]
        }
        let safeStd = max(stdDev, 0.015)

        let sorted = docEntries
            .filter { $0.score >= minSimilarity }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return rowMeta[lhs.idx].mtime > rowMeta[rhs.idx].mtime
            }

        let hits = sorted.prefix(limit).map { entry in
            let meta = rowMeta[entry.idx]
            return SemanticDocumentHit(
                path: meta.path,
                fileName: meta.name,
                kind: meta.kind,
                excerpt: meta.excerpt,
                similarity: entry.score,
                zScore: (entry.score - mean) / safeStd,
                mtime: meta.mtime
            )
        }
        return SemanticDocumentSearchResult(hits: hits, documentCount: docEntries.count, mean: mean, stdDev: stdDev)
    }

    private func reloadMatrixIfNeeded(modelID: String, dimension: Int) {
        guard matrixDirty || matrixModelID != modelID || matrixDimension != dimension else { return }
        matrixData.removeAll(keepingCapacity: true)
        hubnessAdjustment.removeAll(keepingCapacity: true)
        rowMeta.removeAll(keepingCapacity: true)
        matrixModelID = modelID
        matrixDimension = dimension

        var stmt: OpaquePointer?
        let sql = "SELECT path, name, kind, excerpt, mtime, vector FROM doc_chunks WHERE model_id = ? AND dim = ?;"
        guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            matrixDirty = false
            return
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, modelID)
        sqlite3_bind_int64(stmt, 2, Int64(dimension))

        let expectedBytes = dimension * MemoryLayout<Float>.stride
        while sqlite3_step(stmt) == SQLITE_ROW {
            let byteCount = Int(sqlite3_column_bytes(stmt, 5))
            guard byteCount == expectedBytes, let blob = sqlite3_column_blob(stmt, 5) else { continue }
            rowMeta.append(ChunkRowMeta(
                path: columnString(stmt, 0),
                name: columnString(stmt, 1),
                kind: OCRDocumentKind(rawValue: Int(sqlite3_column_int64(stmt, 2))) ?? .pdf,
                excerpt: columnString(stmt, 3),
                mtime: sqlite3_column_double(stmt, 4)
            ))
            let start = matrixData.count
            matrixData.append(contentsOf: repeatElement(Float(0), count: dimension))
            matrixData.withUnsafeMutableBytes { dst in
                guard let base = dst.baseAddress else { return }
                memcpy(base.advanced(by: start * MemoryLayout<Float>.stride), blob, expectedBytes)
            }
        }
        computeHubnessAdjustmentIfNeeded()
        matrixDirty = false
    }

    private func computeHubnessAdjustmentIfNeeded() {
        let rowCount = rowMeta.count
        let dim = matrixDimension
        guard rowCount >= Self.minChunksForHubness, dim > 0 else {
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

    private func lookupStateLocked(path: String) -> SemanticStoreEntry? {
        var stmt: OpaquePointer?
        let sql = "SELECT mtime, size, model_id, status, retry_count FROM doc_state WHERE path = ?;"
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

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    @discardableResult
    private func runStatement(_ sql: String, bind: (OpaquePointer?) -> Void) -> Bool {
        var stmt: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(stmt, idx, value, -1, semanticSQLiteTransient)
    }

    private func columnString(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        sqlite3_column_text(stmt, idx).map { String(cString: $0) } ?? ""
    }
}
