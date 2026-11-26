import Foundation
import os
import SQLite3

/// Matched image record returned by local FTS5 OCR search.
public struct OCRSearchHit: Equatable, Sendable {
    public let path: String
    public let fileName: String
    public let excerpt: String
    public let rank: Double
    public let mtime: Double

    public init(
        path: String,
        fileName: String,
        excerpt: String,
        rank: Double,
        mtime: Double = 0
    ) {
        self.path = path
        self.fileName = fileName
        self.excerpt = excerpt
        self.rank = rank
        self.mtime = mtime
    }
}

/// Summary counts of indexed images and images containing recognized text.
public struct OCRStoreStats: Equatable, Sendable {
    public let indexedCount: Int
    public let withTextCount: Int

    public init(indexedCount: Int, withTextCount: Int) {
        self.indexedCount = indexedCount
        self.withTextCount = withTextCount
    }
}

/// Document kind stored in `ImageOCRStore` for SQL-level `img:` / `pdf:` filtering.
public enum OCRDocumentKind: Int, Equatable, Sendable {
    case image = 0
    case pdf = 1

    public static func from(path: String) -> OCRDocumentKind {
        path.lowercased().hasSuffix(".pdf") ? .pdf : .image
    }
}

/// Stored metadata for an OCR index row including failure retry tracking.
public struct OCRIndexRecord: Equatable, Sendable {
    public let mtime: Double
    public let size: Int64
    public let status: Int
    public let retryCount: Int

    public init(mtime: Double, size: Int64, status: Int, retryCount: Int = 0) {
        self.mtime = mtime
        self.size = size
        self.status = status
        self.retryCount = retryCount
    }
}

/// Lightweight SQLite3 + FTS5 storage backing incremental image OCR search with concurrent WAL reads.
public final class ImageOCRStore: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.quickspot.core", category: "ImageOCRStore")

    public static let statusPending = 0
    public static let statusIndexed = 1
    public static let statusFailed = 2
    public static let maxFailureRetries = 2

    let lock = NSLock()
    let readLock = NSLock()
    var db: OpaquePointer?
    var readDB: OpaquePointer?

    public init(databaseURL: URL? = nil) {
        let targetURL = databaseURL ?? Self.defaultDatabaseURL()
        let isMemory = targetURL.path == ":memory:"
        if !isMemory {
            do {
                try FileManager.default.createDirectory(
                    at: targetURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                Self.logger.error("Failed to create OCR DB directory: \(error.localizedDescription, privacy: .public)")
            }
        }

        var handle: OpaquePointer?
        let path = isMemory ? ":memory:" : targetURL.path
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let handle {
            db = handle
            sqlite3_busy_timeout(handle, 3000)
            if !isMemory { exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;") }
            exec("""
            CREATE TABLE IF NOT EXISTS images (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                path TEXT UNIQUE NOT NULL,
                name TEXT NOT NULL,
                mtime REAL NOT NULL,
                size INTEGER NOT NULL,
                raw_text TEXT NOT NULL,
                status INTEGER NOT NULL DEFAULT 1,
                kind INTEGER NOT NULL DEFAULT 0,
                has_text INTEGER NOT NULL DEFAULT 0,
                retry_count INTEGER NOT NULL DEFAULT 0
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS images_fts USING fts5(name, folded_text, tokenize='unicode61');
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """)
            migrateSchemaIfNeeded()
            if !isMemory {
                var reader: OpaquePointer?
                if sqlite3_open_v2(path, &reader, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let reader {
                    sqlite3_busy_timeout(reader, 3000)
                    readDB = reader
                } else if let reader {
                    sqlite3_close(reader)
                }
            }
        } else {
            Self.logger.error("Failed to open OCR SQLite database")
            sqlite3_close(handle)
        }
    }

    deinit {
        if let readDB { sqlite3_close(readDB) }
        if let db { sqlite3_close(db) }
    }

    public static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("QuickSpot/image-ocr.sqlite")
    }

    public func upsert(
        path: String,
        name: String,
        mtime: Double,
        size: Int64,
        rawText: String,
        foldedText: String,
        status: Int = 1
    ) {
        let kind = OCRDocumentKind.from(path: path).rawValue
        let hasText = rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
        let foldedName = VisionTextExtractor.normalizeForSearch(name)

        lock.lock(); defer { lock.unlock() }
        guard let db else { return }
        guard exec("BEGIN IMMEDIATE;") else { return }

        let existingID = lookupRowID(path: path)
        let rowID: Int64
        let wroteMain: Bool
        if let existingID {
            wroteMain = runStatement(
                "UPDATE images SET name = ?, mtime = ?, size = ?, raw_text = ?, status = ?, kind = ?, has_text = ?, retry_count = 0 WHERE id = ?;"
            ) { s in
                bindText(s, 1, name)
                bindText(s, 2, nil, double: mtime)
                bindInt64(s, 3, size)
                bindText(s, 4, rawText)
                bindInt64(s, 5, Int64(status))
                bindInt64(s, 6, Int64(kind))
                bindInt64(s, 7, Int64(hasText))
                bindInt64(s, 8, existingID)
            }
            guard wroteMain,
                  runStatement("DELETE FROM images_fts WHERE rowid = ?;", bind: { bindInt64($0, 1, existingID) }) else {
                exec("ROLLBACK;")
                return
            }
            rowID = existingID
        } else {
            wroteMain = runStatement(
                "INSERT INTO images (path, name, mtime, size, raw_text, status, kind, has_text, retry_count) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0);"
            ) { s in
                bindText(s, 1, path)
                bindText(s, 2, name)
                bindText(s, 3, nil, double: mtime)
                bindInt64(s, 4, size)
                bindText(s, 5, rawText)
                bindInt64(s, 6, Int64(status))
                bindInt64(s, 7, Int64(kind))
                bindInt64(s, 8, Int64(hasText))
            }
            guard wroteMain else {
                exec("ROLLBACK;")
                return
            }
            rowID = sqlite3_last_insert_rowid(db)
        }

        let wroteFTS: Bool
        if status == Self.statusIndexed {
            wroteFTS = runStatement("INSERT INTO images_fts(rowid, name, folded_text) VALUES (?, ?, ?);") { s in
                bindInt64(s, 1, rowID)
                bindText(s, 2, foldedName)
                bindText(s, 3, foldedText)
            }
        } else {
            wroteFTS = true
        }
        exec(wroteFTS ? "COMMIT;" : "ROLLBACK;")
    }

    /// Records a failed OCR extraction so unreadable/corrupt files are bounded by `maxFailureRetries` instead of looping forever.
    public func recordFailure(path: String, name: String, mtime: Double, size: Int64) {
        let kind = OCRDocumentKind.from(path: path).rawValue
        lock.lock(); defer { lock.unlock() }
        guard db != nil else { return }
        guard exec("BEGIN IMMEDIATE;") else { return }

        if let existing = lookupFailureRow(path: path) {
            let sameVersion = abs(existing.mtime - mtime) <= 0.001 && existing.size == size
            let nextRetries = sameVersion ? (existing.retryCount + 1) : 1
            let ok = runStatement(
                "UPDATE images SET name = ?, mtime = ?, size = ?, raw_text = '', status = ?, kind = ?, has_text = 0, retry_count = ? WHERE id = ?;"
            ) { s in
                bindText(s, 1, name)
                bindText(s, 2, nil, double: mtime)
                bindInt64(s, 3, size)
                bindInt64(s, 4, Int64(Self.statusFailed))
                bindInt64(s, 5, Int64(kind))
                bindInt64(s, 6, Int64(nextRetries))
                bindInt64(s, 7, existing.id)
            }
            let cleanedFTS = ok && runStatement("DELETE FROM images_fts WHERE rowid = ?;") { bindInt64($0, 1, existing.id) }
            exec(cleanedFTS ? "COMMIT;" : "ROLLBACK;")
        } else {
            let ok = runStatement(
                "INSERT INTO images (path, name, mtime, size, raw_text, status, kind, has_text, retry_count) VALUES (?, ?, ?, ?, '', ?, ?, 0, 1);"
            ) { s in
                bindText(s, 1, path)
                bindText(s, 2, name)
                bindText(s, 3, nil, double: mtime)
                bindInt64(s, 4, size)
                bindInt64(s, 5, Int64(Self.statusFailed))
                bindInt64(s, 6, Int64(kind))
            }
            exec(ok ? "COMMIT;" : "ROLLBACK;")
        }
    }

    public func search(query: String, kind: OCRDocumentKind? = nil, limit: Int = 12) -> [OCRSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, limit > 0 else { return [] }
        let tokens = VisionTextExtractor.normalizeForSearch(trimmed)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        let matchExpr = tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")

        typealias RawRow = (path: String, name: String, rawText: String, rank: Double, mtime: Double)
        let rows: [RawRow] = withReadConnection(fallback: []) { conn in
            let sql: String
            if kind != nil {
                sql = """
                SELECT i.path, i.name, i.raw_text, bm25(images_fts), i.mtime
                FROM images_fts JOIN images i ON i.id = images_fts.rowid
                WHERE images_fts MATCH ? AND i.status = 1 AND i.kind = ?
                ORDER BY bm25(images_fts) LIMIT ?;
                """
            } else {
                sql = """
                SELECT i.path, i.name, i.raw_text, bm25(images_fts), i.mtime
                FROM images_fts JOIN images i ON i.id = images_fts.rowid
                WHERE images_fts MATCH ? AND i.status = 1
                ORDER BY bm25(images_fts) LIMIT ?;
                """
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, matchExpr)
            if let kind {
                bindInt64(stmt, 2, Int64(kind.rawValue))
                bindInt64(stmt, 3, Int64(limit))
            } else {
                bindInt64(stmt, 2, Int64(limit))
            }

            var collected: [RawRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                collected.append((
                    path: columnString(stmt, 0),
                    name: columnString(stmt, 1),
                    rawText: columnString(stmt, 2),
                    rank: sqlite3_column_double(stmt, 3),
                    mtime: sqlite3_column_double(stmt, 4)
                ))
            }
            return collected
        }

        // Compute excerpts outside the SQLite read lock so keystroke search stays non-blocking.
        return rows.map { row in
            let excerpt = VisionTextExtractor.extractExcerpt(rawText: row.rawText, query: query) ?? ""
            return OCRSearchHit(
                path: row.path,
                fileName: row.name,
                excerpt: excerpt,
                rank: row.rank,
                mtime: row.mtime
            )
        }
    }
}
