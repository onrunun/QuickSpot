import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Extracted text record from `ImageOCRStore` fed into downstream semantic document chunking without re-running OCR/PDFKit.
public struct OCRTextDocument: Equatable, Sendable {
    public let path: String
    public let name: String
    public let kind: OCRDocumentKind
    public let mtime: Double
    public let size: Int64
    public let rawText: String

    public init(path: String, name: String, kind: OCRDocumentKind, mtime: Double, size: Int64, rawText: String) {
        self.path = path
        self.name = name
        self.kind = kind
        self.mtime = mtime
        self.size = size
        self.rawText = rawText
    }
}

extension ImageOCRStore {
    private static let currentSchemaVersion = 3

    private static let trimExpr = "trim(raw_text, ' ' || char(9) || char(10) || char(13))"

    private static let resetEmptyImagesSQL = """
    UPDATE images
    SET status = 0, retry_count = 0
    WHERE length(\(trimExpr)) = 0
      AND (
        lower(path) LIKE '%.png' OR lower(path) LIKE '%.jpg' OR lower(path) LIKE '%.jpeg'
        OR lower(path) LIKE '%.heic' OR lower(path) LIKE '%.heif' OR lower(path) LIKE '%.webp'
        OR lower(path) LIKE '%.tif' OR lower(path) LIKE '%.tiff' OR lower(path) LIKE '%.bmp'
        OR lower(path) LIKE '%.gif'
      );
    """

    private static let backfillV3ColumnsSQL = """
    UPDATE images
    SET kind = CASE WHEN lower(path) LIKE '%.pdf' THEN 1 ELSE 0 END,
        has_text = CASE WHEN length(\(trimExpr)) > 0 THEN 1 ELSE 0 END;
    """

    func migrateSchemaIfNeeded() {
        guard db != nil else { return }
        if !hasColumn(table: "images", column: "status") {
            exec("ALTER TABLE images ADD COLUMN status INTEGER NOT NULL DEFAULT 1;")
        }
        if !hasColumn(table: "images", column: "kind") {
            exec("ALTER TABLE images ADD COLUMN kind INTEGER NOT NULL DEFAULT 0;")
        }
        if !hasColumn(table: "images", column: "has_text") {
            exec("ALTER TABLE images ADD COLUMN has_text INTEGER NOT NULL DEFAULT 0;")
        }
        if !hasColumn(table: "images", column: "retry_count") {
            exec("ALTER TABLE images ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0;")
        }
        exec("CREATE INDEX IF NOT EXISTS idx_images_status_kind ON images(status, kind);")

        let storedVersion = metaValue(forKey: "schema_version").flatMap(Int.init) ?? 1
        if storedVersion < Self.currentSchemaVersion {
            guard exec("BEGIN IMMEDIATE;") else { return }
            var ok = true
            if storedVersion < 2 {
                ok = ok && exec(Self.resetEmptyImagesSQL)
            }
            if storedVersion < 3 {
                ok = ok && exec(Self.backfillV3ColumnsSQL)
            }
            let marked = ok && runStatement(
                "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', ?);"
            ) { s in
                bindText(s, 1, String(Self.currentSchemaVersion))
            }
            exec(marked ? "COMMIT;" : "ROLLBACK;")
        }
    }

    func withReadConnection<T>(fallback: T, _ body: (OpaquePointer) -> T) -> T {
        if let readDB {
            readLock.lock()
            defer { readLock.unlock() }
            return body(readDB)
        }
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return fallback }
        return body(db)
    }

    public func existingRecords() -> [String: OCRIndexRecord] {
        withReadConnection(fallback: [:]) { conn in
            var map: [String: OCRIndexRecord] = [:]
            var stmt: OpaquePointer?
            let sql = "SELECT path, mtime, size, status, retry_count FROM images;"
            guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return map }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                map[columnString(stmt, 0)] = OCRIndexRecord(
                    mtime: sqlite3_column_double(stmt, 1),
                    size: sqlite3_column_int64(stmt, 2),
                    status: Int(sqlite3_column_int64(stmt, 3)),
                    retryCount: Int(sqlite3_column_int64(stmt, 4))
                )
            }
            return map
        }
    }

    /// Targeted lookup for incremental FSEvents batches without scanning the entire `images` table.
    public func existingRecords(forPaths paths: [String]) -> [String: OCRIndexRecord] {
        guard !paths.isEmpty else { return [:] }
        return withReadConnection(fallback: [:]) { conn in
            var map: [String: OCRIndexRecord] = [:]
            map.reserveCapacity(paths.count)
            let chunkSize = 200
            var offset = 0
            while offset < paths.count {
                let end = min(offset + chunkSize, paths.count)
                let slice = paths[offset..<end]
                let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
                let sql = "SELECT path, mtime, size, status, retry_count FROM images WHERE path IN (\(placeholders));"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK {
                    for (idx, path) in slice.enumerated() {
                        bindText(stmt, Int32(idx + 1), path)
                    }
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        map[columnString(stmt, 0)] = OCRIndexRecord(
                            mtime: sqlite3_column_double(stmt, 1),
                            size: sqlite3_column_int64(stmt, 2),
                            status: Int(sqlite3_column_int64(stmt, 3)),
                            retryCount: Int(sqlite3_column_int64(stmt, 4))
                        )
                    }
                    sqlite3_finalize(stmt)
                }
                offset = end
            }
            return map
        }
    }

    public func existingEntries() -> [String: (mtime: Double, size: Int64, status: Int)] {
        existingRecords().mapValues { ($0.mtime, $0.size, $0.status) }
    }

    public func existingMetadata() -> [String: (mtime: Double, size: Int64)] {
        existingRecords().mapValues { ($0.mtime, $0.size) }
    }

    public func delete(paths: [String]) {
        guard !paths.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard db != nil else { return }
        var staleIDs: [Int64] = []
        staleIDs.reserveCapacity(paths.count)
        for path in paths {
            if let rowID = lookupRowID(path: path) {
                staleIDs.append(rowID)
            }
        }
        deleteRowIDsLocked(staleIDs)
    }

    /// Immediately removes all indexed rows matching `folderPath` or nested beneath it (safe even when paused/disabled).
    public func deleteUnderFolder(_ folderPath: String) {
        let std = (folderPath as NSString).standardizingPath
        let clean = std.count > 1 && std.hasSuffix("/") ? String(std.dropLast()) : std
        guard !clean.isEmpty else { return }

        let escaped = Self.escapeLikePrefix(clean)
        let prefixPattern = clean == "/" ? "/%" : "\(escaped)/%"

        lock.lock(); defer { lock.unlock() }
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "SELECT id FROM images WHERE path = ? OR path LIKE ? ESCAPE '\\';"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        bindText(stmt, 1, clean)
        bindText(stmt, 2, prefixPattern)
        var staleIDs: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            staleIDs.append(sqlite3_column_int64(stmt, 0))
        }
        sqlite3_finalize(stmt)
        deleteRowIDsLocked(staleIDs)
    }

    public func deleteMissing(keeping paths: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, "SELECT id, path FROM images;", -1, &stmt, nil) == SQLITE_OK else { return }
        var staleIDs: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if !paths.contains(columnString(stmt, 1)) { staleIDs.append(sqlite3_column_int64(stmt, 0)) }
        }
        sqlite3_finalize(stmt)
        deleteRowIDsLocked(staleIDs)
    }

    public func resetEmptyImages() {
        lock.lock(); defer { lock.unlock() }
        guard exec("BEGIN IMMEDIATE;") else { return }
        let ok = exec("UPDATE images SET status = 0, retry_count = 0 WHERE status = 2;")
            && exec(Self.resetEmptyImagesSQL)
        exec(ok ? "COMMIT;" : "ROLLBACK;")
    }

    public func clearAll() {
        lock.lock(); defer { lock.unlock() }
        guard exec("BEGIN IMMEDIATE;") else { return }
        let ok = exec("DELETE FROM images_fts; DELETE FROM images;")
        exec(ok ? "COMMIT;" : "ROLLBACK;")
    }

    public func stats() -> OCRStoreStats {
        withReadConnection(fallback: OCRStoreStats(indexedCount: 0, withTextCount: 0)) { conn in
            var stmt: OpaquePointer?
            let sql = "SELECT COUNT(*), COALESCE(SUM(has_text), 0) FROM images WHERE status = 1;"
            guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else {
                return OCRStoreStats(indexedCount: 0, withTextCount: 0)
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return OCRStoreStats(indexedCount: 0, withTextCount: 0)
            }
            return OCRStoreStats(
                indexedCount: Int(sqlite3_column_int64(stmt, 0)),
                withTextCount: Int(sqlite3_column_int64(stmt, 1))
            )
        }
    }

    public func rawText(forPath path: String) -> String? {
        withReadConnection(fallback: nil) { conn in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(conn, "SELECT raw_text FROM images WHERE path = ?;", -1, &stmt, nil) == SQLITE_OK else {
                return nil
            }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, path)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let trimmed = columnString(stmt, 0).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Returns all successfully indexed text-bearing OCR/PDF documents ordered newest-first for semantic text embedding.
    public func textDocuments() -> [OCRTextDocument] {
        withReadConnection(fallback: []) { conn in
            var stmt: OpaquePointer?
            let sql = "SELECT path, name, kind, mtime, size, raw_text FROM images WHERE status = 1 AND has_text = 1 ORDER BY mtime DESC;"
            guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var docs: [OCRTextDocument] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                docs.append(OCRTextDocument(
                    path: columnString(stmt, 0),
                    name: columnString(stmt, 1),
                    kind: OCRDocumentKind(rawValue: Int(sqlite3_column_int64(stmt, 2))) ?? .image,
                    mtime: sqlite3_column_double(stmt, 3),
                    size: sqlite3_column_int64(stmt, 4),
                    rawText: columnString(stmt, 5)
                ))
            }
            return docs
        }
    }

    /// Returns indexed text-bearing OCR/PDF documents for a targeted subset of paths (incremental updates).
    public func textDocuments(forPaths paths: [String]) -> [OCRTextDocument] {
        guard !paths.isEmpty else { return [] }
        return withReadConnection(fallback: []) { conn in
            var docs: [OCRTextDocument] = []
            let chunkSize = 200
            var offset = 0
            while offset < paths.count {
                let end = min(offset + chunkSize, paths.count)
                let slice = paths[offset..<end]
                let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
                let sql = "SELECT path, name, kind, mtime, size, raw_text FROM images WHERE status = 1 AND has_text = 1 AND path IN (\(placeholders));"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK {
                    for (idx, path) in slice.enumerated() {
                        bindText(stmt, Int32(idx + 1), path)
                    }
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        docs.append(OCRTextDocument(
                            path: columnString(stmt, 0),
                            name: columnString(stmt, 1),
                            kind: OCRDocumentKind(rawValue: Int(sqlite3_column_int64(stmt, 2))) ?? .image,
                            mtime: sqlite3_column_double(stmt, 3),
                            size: sqlite3_column_int64(stmt, 4),
                            rawText: columnString(stmt, 5)
                        ))
                    }
                    sqlite3_finalize(stmt)
                }
                offset = end
            }
            return docs
        }
    }

    func lookupRowID(path: String) -> Int64? {
        var stmt: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, "SELECT id FROM images WHERE path = ?;", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, path)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    func lookupFailureRow(path: String) -> (id: Int64, mtime: Double, size: Int64, retryCount: Int)? {
        var stmt: OpaquePointer?
        let sql = "SELECT id, mtime, size, retry_count FROM images WHERE path = ?;"
        guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, path)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (
            id: sqlite3_column_int64(stmt, 0),
            mtime: sqlite3_column_double(stmt, 1),
            size: sqlite3_column_int64(stmt, 2),
            retryCount: Int(sqlite3_column_int64(stmt, 3))
        )
    }

    private func deleteRowIDsLocked(_ staleIDs: [Int64]) {
        guard !staleIDs.isEmpty, let db else { return }
        guard exec("BEGIN IMMEDIATE;") else { return }
        var delFTS: OpaquePointer?
        var delImg: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM images_fts WHERE rowid = ?;", -1, &delFTS, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "DELETE FROM images WHERE id = ?;", -1, &delImg, nil) == SQLITE_OK else {
            sqlite3_finalize(delFTS)
            sqlite3_finalize(delImg)
            exec("ROLLBACK;")
            return
        }
        defer {
            sqlite3_finalize(delFTS)
            sqlite3_finalize(delImg)
        }
        for id in staleIDs {
            sqlite3_reset(delFTS)
            sqlite3_bind_int64(delFTS, 1, id)
            _ = sqlite3_step(delFTS)

            sqlite3_reset(delImg)
            sqlite3_bind_int64(delImg, 1, id)
            _ = sqlite3_step(delImg)
        }
        exec("COMMIT;")
    }

    private static func escapeLikePrefix(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
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

    private func metaValue(forKey key: String) -> String? {
        var stmt: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?;", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        return sqlite3_step(stmt) == SQLITE_ROW ? columnString(stmt, 0) : nil
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

    func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?, double: Double? = nil) {
        if let double {
            sqlite3_bind_double(stmt, idx, double)
            return
        }
        sqlite3_bind_text(stmt, idx, value ?? "", -1, sqliteTransient)
    }

    func bindInt64(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Int64) {
        sqlite3_bind_int64(stmt, idx, value)
    }

    func columnString(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        sqlite3_column_text(stmt, idx).map { String(cString: $0) } ?? ""
    }
}
