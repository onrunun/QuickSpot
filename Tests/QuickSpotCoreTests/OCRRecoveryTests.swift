import AppKit
import Foundation
import SQLite3
import XCTest
@testable import QuickSpotCore

final class OCRRecoveryTests: XCTestCase {
    // MARK: - v1 -> v2 Schema Migration

    func testImageOCRStoreV1ToV2SchemaMigrationAndIdempotency() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickspot-ocr-v1-\(UUID().uuidString).sqlite")
        defer { cleanupSQLiteFiles(at: dbURL) }

        // Build a legacy v1 SQLite DB (no `status` column, no `meta` table)
        var rawDB: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(dbURL.path, &rawDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK
        )
        let handle = try XCTUnwrap(rawDB)
        let setupSQL = """
        CREATE TABLE images (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT UNIQUE NOT NULL,
            name TEXT NOT NULL,
            mtime REAL NOT NULL,
            size INTEGER NOT NULL,
            raw_text TEXT NOT NULL
        );
        CREATE VIRTUAL TABLE images_fts USING fts5(name, folded_text, tokenize='unicode61');
        INSERT INTO images (id, path, name, mtime, size, raw_text)
            VALUES (1, '/tmp/empty.png', 'empty.png', 100.0, 5000, '   \n');
        INSERT INTO images_fts (rowid, name, folded_text)
            VALUES (1, 'empty.png', '');
        INSERT INTO images (id, path, name, mtime, size, raw_text)
            VALUES (2, '/tmp/receipt.png', 'receipt.png', 200.0, 6000, 'Fatura 500 TL');
        INSERT INTO images_fts (rowid, name, folded_text)
            VALUES (2, 'receipt.png', 'fatura 500 tl');
        INSERT INTO images (id, path, name, mtime, size, raw_text)
            VALUES (3, '/tmp/scan.pdf', 'scan.pdf', 300.0, 7000, '');
        INSERT INTO images_fts (rowid, name, folded_text)
            VALUES (3, 'scan.pdf', '');
        """
        XCTAssertEqual(sqlite3_exec(handle, setupSQL, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(handle), SQLITE_OK)

        // Open with ImageOCRStore to trigger v1 -> v2 migration
        var store: ImageOCRStore? = ImageOCRStore(databaseURL: dbURL)
        let entries = try XCTUnwrap(store?.existingEntries())
        XCTAssertEqual(entries["/tmp/empty.png"]?.status, 0)
        XCTAssertEqual(entries["/tmp/receipt.png"]?.status, 1)
        XCTAssertEqual(entries["/tmp/scan.pdf"]?.status, 1)
        XCTAssertEqual(store?.stats(), OCRStoreStats(indexedCount: 2, withTextCount: 1))
        XCTAssertEqual(store?.search(query: "empty"), [])
        XCTAssertEqual(store?.search(query: "fatura").count, 1)

        // Simulate empty PNG genuinely re-indexed with status=1, then reopen to verify migration is idempotent
        store?.upsert(
            path: "/tmp/empty.png",
            name: "empty.png",
            mtime: 100.0,
            size: 5000,
            rawText: "",
            foldedText: "",
            status: 1
        )
        store = nil

        let reopened = ImageOCRStore(databaseURL: dbURL)
        let entriesAfterReopen = reopened.existingEntries()
        XCTAssertEqual(entriesAfterReopen["/tmp/empty.png"]?.status, 1)
        XCTAssertEqual(entriesAfterReopen["/tmp/receipt.png"]?.status, 1)
        XCTAssertEqual(entriesAfterReopen["/tmp/scan.pdf"]?.status, 1)
        XCTAssertEqual(reopened.stats(), OCRStoreStats(indexedCount: 3, withTextCount: 1))
    }

    // MARK: - Corrupt Image & PDF Failure Propagation

    func testCorruptPNGAndPDFReturnFailureResult() throws {
        let dir = FileManager.default.temporaryDirectory
        let corruptPNG = dir.appendingPathComponent("quickspot-corrupt-\(UUID().uuidString).png")
        let corruptPDF = dir.appendingPathComponent("quickspot-corrupt-\(UUID().uuidString).pdf")
        let missingPNG = dir.appendingPathComponent("quickspot-missing-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: corruptPNG)
            try? FileManager.default.removeItem(at: corruptPDF)
        }

        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0xDE, 0xAD]).write(to: corruptPNG)
        try Data("not a valid pdf".utf8).write(to: corruptPDF)

        switch VisionTextExtractor.extractTextResult(from: corruptPNG) {
        case .success(let text):
            XCTFail("Corrupt PNG should return .failure, got .success(\"\(text)\")")
        case .failure(let error):
            XCTAssertEqual(error as? OCRExtractionError, .unreadableImage)
        }

        switch VisionTextExtractor.extractTextResult(from: missingPNG) {
        case .success:
            XCTFail("Missing PNG should return .failure")
        case .failure(let error):
            XCTAssertEqual(error as? OCRExtractionError, .unreadableImage)
        }

        switch VisionTextExtractor.extractTextResult(from: corruptPDF) {
        case .success:
            XCTFail("Corrupt PDF should return .failure")
        case .failure(let error):
            XCTAssertEqual(error as? OCRExtractionError, .unreadableImage)
        }
    }

    // MARK: - Multi-Page Digital PDF (>8 Pages)

    func testTwelvePageDigitalPDFExtractsPageTwelve() throws {
        let pdfURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickspot-12pages-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        var mediaBox = CGRect(x: 0, y: 0, width: 720, height: 240)
        guard let ctx = CGContext(pdfURL as CFURL, mediaBox: &mediaBox, nil) else {
            XCTFail("Failed to create multi-page PDF context")
            return
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.black
        ]
        for page in 1...12 {
            ctx.beginPDFPage(nil)
            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsCtx
            let marker = page == 12
                ? "QuickSpot Digital Page 12 Final Sentinel 9912"
                : "QuickSpot Digital Page \(page) Embedded Text Marker \(1000 + page)"
            NSString(string: marker).draw(at: NSPoint(x: 24, y: 140), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()

        let result = PDFTextExtractor.extractTextResult(from: pdfURL)
        switch result {
        case .failure(let error):
            XCTFail("Expected digital PDF extraction to succeed, got error: \(error)")
        case .success(let text):
            XCTAssertTrue(text.contains("Marker 1001"), "Missing page 1 text")
            XCTAssertTrue(text.contains("Final Sentinel 9912"), "Missing page 12 text: \(text)")
        }

        let capped8 = PDFTextExtractor.extractText(from: pdfURL, maxPages: 8)
        XCTAssertTrue(capped8.contains("Marker 1001"))
        XCTAssertFalse(capped8.contains("Final Sentinel 9912"))
    }

    private func cleanupSQLiteFiles(at dbURL: URL) {
        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-shm"))
    }
}
