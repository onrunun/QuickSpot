import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension ImageOCRStore {
    private static let currentSchemaVersion = 2

    private static let trimExpr = "trim(raw_text, ' ' || char(9) || char(10) || char(13))"

    private static let resetEmptyImagesSQL = """
    UPDATE images
    SET status = 0
    WHERE length(\(trimExpr)) = 0
      AND (
        lower(path) LIKE '%.png' OR lower(path) LIKE '%.jpg' OR lower(path) LIKE '%.jpeg'
        OR lower(path) LIKE '%.heic' OR lower(path) LIKE '%.heif' OR lower(path) LIKE '%.webp'
        OR lower(path) LIKE '%.tif' OR lower(path) LIKE '%.tiff' OR lower(path) LIKE '%.bmp'
        OR lower(path) LIKE '%.gif'
      );
    """

    func migrateSchemaIfNeeded() {
        guard db != nil else { return }
        if !hasColumn(table: "images", column: "status") {
            exec("ALTER TABLE images ADD COLUMN status INTEGER NOT NULL DEFAULT 1;")
        }
        let storedVersion = metaValue(forKey: "schema_version").flatMap(Int.init) ?? 1
        if storedVersion < Self.currentSchemaVersion {
            guard exec("BEGIN IMMEDIATE;") else { return }
            let healed = exec(Self.resetEmptyImagesSQL)
            let marked = runStatement(
                "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', ?);"
            ) { s in
                bindText(s, 1, String(Self.currentSchemaVersion))
            }
            exec((healed && marked) ? "COMMIT;" : "ROLLBACK;")
        }
    }

    public func existingEntries() -> [String: (mtime: Double, size: Int64, status: Int)] {
        lock.lock(); defer { lock.unlock() }
        var map: [String: (mtime: Double, size: Int64, status: Int)] = [:]
        var stmt: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, "SELECT path, mtime, size, status FROM images;", -1, &stmt, nil) == SQLITE_OK else {
            return map
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            map[columnString(stmt, 0)] = (
                sqlite3_column_double(stmt, 1),
                sqlite3_column_int64(stmt, 2),
                Int(sqlite3_column_int64(stmt, 3))
            )
        }
        return map
    }

    public func existingMetadata() -> [String: (mtime: Double, size: Int64)] {
        existingEntries().mapValues { ($0.mtime, $0.size) }
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
        guard !staleIDs.isEmpty else { return }
        guard exec("BEGIN IMMEDIATE;") else { return }
        for id in staleIDs {
            runStatement("DELETE FROM images_fts WHERE rowid = ?;") { bindInt64($0, 1, id) }
            runStatement("DELETE FROM images WHERE id = ?;") { bindInt64($0, 1, id) }
        }
        exec("COMMIT;")
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
        guard !staleIDs.isEmpty else { return }
        guard exec("BEGIN IMMEDIATE;") else { return }
        for id in staleIDs {
            runStatement("DELETE FROM images_fts WHERE rowid = ?;") { bindInt64($0, 1, id) }
            runStatement("DELETE FROM images WHERE id = ?;") { bindInt64($0, 1, id) }
        }
        exec("COMMIT;")
    }

    public func resetEmptyImages() {
        lock.lock(); defer { lock.unlock() }
        exec(Self.resetEmptyImagesSQL)
    }

    public func clearAll() {
        lock.lock(); defer { lock.unlock() }
        exec("DELETE FROM images_fts; DELETE FROM images;")
    }

    public func stats() -> OCRStoreStats {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        let sql = """
        SELECT COUNT(*), COALESCE(SUM(CASE WHEN length(\(Self.trimExpr)) > 0 THEN 1 ELSE 0 END), 0)
        FROM images
        WHERE status = 1;
        """
        guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return OCRStoreStats(indexedCount: 0, withTextCount: 0)
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return OCRStoreStats(indexedCount: 0, withTextCount: 0) }
        return OCRStoreStats(
            indexedCount: Int(sqlite3_column_int64(stmt, 0)),
            withTextCount: Int(sqlite3_column_int64(stmt, 1))
        )
    }

    public func rawText(forPath path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, "SELECT raw_text FROM images WHERE path = ?;", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, path)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let trimmed = columnString(stmt, 0).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
