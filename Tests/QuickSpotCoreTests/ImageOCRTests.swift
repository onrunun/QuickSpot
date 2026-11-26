import AppKit
import XCTest
@testable import QuickSpotCore

final class ImageOCRTests: XCTestCase {
    func testIndexSettingsStoreAddRemovePersistence() {
        let suiteName = "QuickSpotTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = IndexSettingsStore(defaults: defaults)
        let initial = store.load()
        XCTAssertFalse(initial.indexOnBattery)
        XCTAssertTrue(initial.isOCREnabled)

        let added = store.addFolder("/tmp/quickspot-ocr-a")
        XCTAssertTrue(added.folders.contains("/tmp/quickspot-ocr-a"))

        let persisted = store.load()
        XCTAssertTrue(persisted.folders.contains("/tmp/quickspot-ocr-a"))

        let removed = store.removeFolder("/tmp/quickspot-ocr-a")
        XCTAssertFalse(removed.folders.contains("/tmp/quickspot-ocr-a"))
    }

    func testImageOCRStoreFTS5TurkishAndSanitization() {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickspot-ocr-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-shm"))
        }

        let store = ImageOCRStore(databaseURL: dbURL)
        let raw = "Fatura tutarı 1.250,00 TL ödendi\nŞişli Şubesi"
        store.upsert(
            path: "/tmp/fatura-1.png",
            name: "fatura-1.png",
            mtime: 100.0,
            size: 8192,
            rawText: raw,
            foldedText: VisionTextExtractor.normalizeForSearch(raw)
        )

        XCTAssertEqual(store.stats(), OCRStoreStats(indexedCount: 1, withTextCount: 1))

        let faturaHits = store.search(query: "fatura")
        XCTAssertEqual(faturaHits.count, 1)
        XCTAssertTrue(faturaHits.first?.excerpt.contains("Fatura") == true)
        XCTAssertEqual(store.rawText(forPath: "/tmp/fatura-1.png"), raw)

        let sisliHits = store.search(query: "sisli odendi")
        XCTAssertEqual(sisliHits.count, 1)

        // Malformed FTS syntax should safely sanitize instead of failing.
        XCTAssertEqual(store.search(query: "(\"test\":* -!)"), [])

        store.deleteMissing(keeping: [])
        XCTAssertEqual(store.stats(), OCRStoreStats(indexedCount: 0, withTextCount: 0))

        store.upsert(
            path: "/tmp/temp.png",
            name: "temp.png",
            mtime: 1.0,
            size: 5000,
            rawText: "Merhaba",
            foldedText: "merhaba"
        )
        store.clearAll()
        XCTAssertEqual(store.stats().indexedCount, 0)
    }

    func testVisionTextExtractorOnRenderedImage() throws {
        let pngURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickspot-vision-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: pngURL) }

        let width = 460
        let height = 140
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            XCTFail("Failed to allocate bitmap")
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSString("QUICKSPOT 2026").draw(
            at: NSPoint(x: 40, y: 46),
            withAttributes: [.font: NSFont.boldSystemFont(ofSize: 38), .foregroundColor: NSColor.black]
        )
        NSGraphicsContext.restoreGraphicsState()

        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: pngURL)

        let text = VisionTextExtractor.extractText(from: pngURL).uppercased()
        XCTAssertTrue(text.contains("QUICKSPOT") || text.contains("2026"), "Extracted text was: \(text)")
    }

    func testPDFTextExtractorOnGeneratedPDF() throws {
        let pdfURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickspot-pdf-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 200)
        guard let ctx = CGContext(pdfURL as CFURL, mediaBox: &mediaBox, nil) else {
            XCTFail("Failed to create PDF context")
            return
        }
        ctx.beginPDFPage(nil)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        NSString("Fatura No 8842 QuickSpot PDF Test").draw(
            at: NSPoint(x: 24, y: 120),
            withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black]
        )
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()

        let extracted = PDFTextExtractor.extractText(from: pdfURL)
        XCTAssertTrue(extracted.contains("8842") || extracted.contains("QuickSpot"), "PDF text was: \(extracted)")
    }
}
