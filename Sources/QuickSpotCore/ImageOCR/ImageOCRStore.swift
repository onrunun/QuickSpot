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

/// Lightweight SQLite3 + FTS5 storage backing incremental image OCR search.
public final class ImageOCRStore: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.quickspot.core", category: "ImageOCRStore")

    let lock = NSLock()
    var db: OpaquePointer?

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
                status INTEGER NOT NULL DEFAULT 1
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS images_fts USING fts5(name, folded_text, tokenize='unicode61');
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """)
            migrateSchemaIfNeeded()
        } else {
            sqlite3_close(handle)
        }
    }

    deinit {
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
        lock.lock(); defer { lock.unlock() }
        guard let db else { return }
        guard exec("BEGIN IMMEDIATE;") else { return }

        let existingID = lookupRowID(path: path)
        let rowID: Int64
        let wroteMain: Bool
        if let existingID {
            wroteMain = runStatement(
                "UPDATE images SET name = ?, mtime = ?, size = ?, raw_text = ?, status = ? WHERE id = ?;"
            ) { s in
                bindText(s, 1, name)
                bindText(s, 2, nil, double: mtime)
                bindInt64(s, 3, size)
                bindText(s, 4, rawText)
                bindInt64(s, 5, Int64(status))
                bindInt64(s, 6, existingID)
            }
            guard wroteMain,
                  runStatement("DELETE FROM images_fts WHERE rowid = ?;", bind: { bindInt64($0, 1, existingID) }) else {
                exec("ROLLBACK;")
                return
            }
            rowID = existingID
        } else {
            wroteMain = runStatement(
                "INSERT INTO images (path, name, mtime, size, raw_text, status) VALUES (?, ?, ?, ?, ?, ?);"
            ) { s in
                bindText(s, 1, path)
                bindText(s, 2, name)
                bindText(s, 3, nil, double: mtime)
                bindInt64(s, 4, size)
                bindText(s, 5, rawText)
                bindInt64(s, 6, Int64(status))
            }
            guard wroteMain else {
                exec("ROLLBACK;")
                return
            }
            rowID = sqlite3_last_insert_rowid(db)
        }

        let foldedName = VisionTextExtractor.normalizeForSearch(name)
        let wroteFTS = runStatement("INSERT INTO images_fts(rowid, name, folded_text) VALUES (?, ?, ?);") { s in
            bindInt64(s, 1, rowID)
            bindText(s, 2, foldedName)
            bindText(s, 3, foldedText)
        }
        exec(wroteFTS ? "COMMIT;" : "ROLLBACK;")
    }

    public func search(query: String, limit: Int = 12) -> [OCRSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let tokens = VisionTextExtractor.normalizeForSearch(trimmed)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        let matchExpr = tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")

        lock.lock(); defer { lock.unlock() }
        let sql = """
        SELECT i.path, i.name, i.raw_text, bm25(images_fts), i.mtime
        FROM images_fts JOIN images i ON i.id = images_fts.rowid
        WHERE images_fts MATCH ? AND i.status = 1
        ORDER BY bm25(images_fts) LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, matchExpr)
        bindInt64(stmt, 2, Int64(limit))

        var hits: [OCRSearchHit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = columnString(stmt, 0)
            let name = columnString(stmt, 1)
            let rawText = columnString(stmt, 2)
            let rank = sqlite3_column_double(stmt, 3)
            let mtime = sqlite3_column_double(stmt, 4)
            let excerpt = VisionTextExtractor.extractExcerpt(rawText: rawText, query: query) ?? ""
            hits.append(OCRSearchHit(path: path, fileName: name, excerpt: excerpt, rank: rank, mtime: mtime))
        }
        return hits
    }
}
