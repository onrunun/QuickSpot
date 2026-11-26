import AppKit
import Foundation
import XCTest
@testable import QuickSpotCore

private final class MockMultimodalDocProvider: SemanticEmbeddingProvider, @unchecked Sendable {
    let modelIdentifier: String = "mock-doc-gemma:4d"
    let dimension: Int = 4
    let status: SemanticModelStatus
    let textModelReady: Bool

    init(status: SemanticModelStatus, textModelReady: Bool = true) {
        self.status = status
        self.textModelReady = textModelReady
    }

    func modelStatus() async -> SemanticModelStatus { status }
    func isTextModelReady() async -> Bool { textModelReady }

    func embedQuery(_ text: String) async throws -> [Float] {
        let lower = text.lowercased()
        if lower.contains("lease") || lower.contains("kira") {
            return [1, 0, 0, 0]
        }
        if lower.contains("invoice") || lower.contains("fatura") {
            return [0, 1, 0, 0]
        }
        return [0, 0, 0, 1]
    }

    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            let lower = text.lowercased()
            if lower.contains("kiralama") || lower.contains("tasinmaz") || lower.contains("kira") {
                return [1, 0, 0, 0]
            }
            if lower.contains("odeme") || lower.contains("fatura") || lower.contains("toplam") {
                return [0, 1, 0, 0]
            }
            return [0, 0, 1, 0]
        }
    }

    func embedImages(_ urls: [URL]) async throws -> [(url: URL, vector: [Float])] {
        urls.map { ($0, [0, 0, 1, 0]) }
    }

    func releaseImageEncoder() async {}
    func unloadAll() async {}
}

final class SemanticDocumentAndTilingTests: XCTestCase {
    func testScrollingScreenshotTilingPreservesTopAndBottomLegibilityAndDeduplicatesOverlap() throws {
        let pngURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickspot-tall-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: pngURL) }

        let width = 800
        let height = 3600
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            XCTFail("Failed to allocate tall bitmap")
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 42),
            .foregroundColor: NSColor.black
        ]
        // AppKit origin is bottom-left: y=3420 is top of image, y=1800 middle, y=140 bottom.
        NSString("ALPHA TOP HEADER 1111").draw(at: NSPoint(x: 40, y: 3420), withAttributes: attrs)
        NSString("BETA MIDDLE BODY 2222").draw(at: NSPoint(x: 40, y: 1800), withAttributes: attrs)
        NSString("GAMMA BOTTOM FOOTER 3333").draw(at: NSPoint(x: 40, y: 140), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()

        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: pngURL)

        let tiles = try XCTUnwrap(VisionTextExtractor.loadScrollingTilesIfNeeded(from: pngURL, maxPixel: 1600))
        XCTAssertGreaterThanOrEqual(tiles.count, 2)
        XCTAssertEqual(tiles.first?.width, 800)

        let extracted = VisionTextExtractor.extractText(from: pngURL, maxPixel: 1600).uppercased()
        XCTAssertTrue(extracted.contains("1111") || extracted.contains("ALPHA"), "Missing top tile text: \(extracted)")
        XCTAssertTrue(extracted.contains("2222") || extracted.contains("BETA"), "Missing middle tile text: \(extracted)")
        XCTAssertTrue(extracted.contains("3333") || extracted.contains("GAMMA"), "Missing bottom tile text: \(extracted)")

        let merged = VisionTextExtractor.mergeTiledOCRTexts([
            "Line One\nLine Two\nShared Boundary",
            "Shared Boundary\nLine Four\nLine Five"
        ])
        XCTAssertEqual(merged, "Line One\nLine Two\nShared Boundary\nLine Four\nLine Five")
    }

    func testSemanticDocumentChunkerRespectsMinLengthOverlapAndCap() {
        XCTAssertTrue(SemanticDocumentChunker.chunk(fileName: "tiny.png", rawText: "OK 12:34").isEmpty)

        let longParagraphs = (1...25)
            .map { "Madde \($0): Taşınmaz kiralama protokolü kapsamında aylık kira ödeme koşulları ve depozito hükümleri belirtilmiştir." }
            .joined(separator: "\n")
        let chunks = SemanticDocumentChunker.chunk(
            fileName: "ev_kira_sozlesmesi.pdf",
            rawText: longParagraphs,
            maxChunkChars: 350,
            overlapChars: 60,
            maxChunks: 6
        )
        XCTAssertGreaterThanOrEqual(chunks.count, 2)
        XCTAssertLessThanOrEqual(chunks.count, 6)
        XCTAssertTrue(chunks[0].embedInput.hasPrefix("title: ev kira sozlesmesi\n"))
        XCTAssertLessThanOrEqual(chunks[0].excerpt.count, 150)
    }

    func testSemanticPDFAndOCRDocumentSearchFilterAndPruneWorkWithTextModelOnly() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("quickspot-semdoc-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let leasePDF = tempDir.appendingPathComponent("ev_protokolu.pdf")
        let invoicePNG = tempDir.appendingPathComponent("ekran_ozeti.png")
        try Data("pdf".utf8).write(to: leasePDF)
        try Data("png".utf8).write(to: invoicePNG)

        let ocrStore = ImageOCRStore(databaseURL: tempDir.appendingPathComponent("ocr.sqlite"))
        let now = Date().timeIntervalSince1970
        let leaseText = "Taşınmaz kiralama protokolü ve aylık kira ödeme koşulları birinci maddede açıkça düzenlenmiştir."
        let invoiceText = "Aylık elektrik faturası toplam ödeme tutarı 1.450 TL olarak son ödeme tarihine kadar tahsil edilir."
        ocrStore.upsert(
            path: leasePDF.path, name: leasePDF.lastPathComponent, mtime: now, size: 4096,
            rawText: leaseText, foldedText: VisionTextExtractor.normalizeForSearch(leaseText), status: 1
        )
        ocrStore.upsert(
            path: invoicePNG.path, name: invoicePNG.lastPathComponent, mtime: now - 10, size: 5000,
            rawText: invoiceText, foldedText: VisionTextExtractor.normalizeForSearch(invoiceText), status: 1
        )

        let suite = "QuickSpotSemDoc-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folderStore = IndexSettingsStore(defaults: defaults)
        folderStore.save(IndexSettings(folders: [tempDir.path], indexOnBattery: true, isOCREnabled: true))
        let semSettings = SemanticSettingsStore(defaults: defaults)
        semSettings.save(SemanticSettings(isEnabled: true, customModelsDirectory: nil))

        // Even when mmproj is missing (status == .missing), text-only semantic document search still works!
        let missingVisualStatus = SemanticModelStatus.missing(
            directory: tempDir,
            missingFiles: [SemanticModelLocator.mmprojModelFileName]
        )
        let provider = MockMultimodalDocProvider(status: missingVisualStatus, textModelReady: true)
        let docStore = SemanticDocumentStore(databaseURL: tempDir.appendingPathComponent("docs.sqlite"))
        let docIndexer = SemanticDocumentIndexer(
            documentStore: docStore,
            ocrStore: ocrStore,
            engine: provider,
            generalMinSimilarity: 0.5,
            filteredMinSimilarity: 0.5
        )
        let semIndexer = SemanticImageIndexer(
            store: SemanticVectorStore(databaseURL: tempDir.appendingPathComponent("vis.sqlite")),
            documentIndexer: docIndexer,
            engine: provider,
            folderSettingsStore: folderStore,
            semanticSettingsStore: semSettings
        )

        await semIndexer.runCoordinatedDocumentPass(force: true)
        XCTAssertEqual(docIndexer.documentCount(), 2)
        XCTAssertEqual(semIndexer.currentSnapshot().embeddedDocumentCount, 2)

        // Semantic PDF search finds lease PDF even with zero keyword overlap ("lease agreement" vs Turkish text).
        let pdfHits = await semIndexer.searchAsync(query: "lease agreement", filter: .pdfOnly, limit: 5)
        XCTAssertEqual(pdfHits.map(\.title), ["ev_protokolu.pdf"])
        XCTAssertEqual(pdfHits.first?.matchSource, .semanticText)
        XCTAssertTrue(pdfHits.first?.matchedSnippet?.contains("kiralama") == true)

        // Image filter scopes document semantic hits to image OCR documents only.
        let imgHits = await semIndexer.searchAsync(query: "invoice payment", filter: .imagesOnly, limit: 5)
        XCTAssertEqual(imgHits.map(\.title), ["ekran_ozeti.png"])
        XCTAssertEqual(imgHits.first?.matchSource, .semanticText)

        // ResultRanker fuses `.semanticText` cleanly with filename hits.
        let nameHit = SearchItem(
            id: "file:\(leasePDF.path)", title: leasePDF.lastPathComponent, subtitle: "~",
            category: .file, iconPath: leasePDF.path, score: 780,
            action: .openFile(leasePDF), previewURL: leasePDF, matchSource: .name
        )
        let merged = ResultRanker.mergeDeduplicatingFiles(ocr: pdfHits, files: [nameHit])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].score, 850)

        // Pruning folder immediately removes semantic document chunks too.
        semIndexer.pruneFolder(tempDir.path)
        XCTAssertEqual(docIndexer.documentCount(), 0)
    }

    func testTextOnlyGGUFResolutionWithoutMMProj() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickspot-textonly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        XCTAssertNil(SemanticModelLocator.resolveTextModelURL(in: tmpDir))

        var validGGUF = Data([0x47, 0x47, 0x55, 0x46, 0x03, 0x00, 0x00, 0x00])
        validGGUF.append(Data(repeating: 0x00, count: 1_100_000))
        try validGGUF.write(to: tmpDir.appendingPathComponent(SemanticModelLocator.textModelFileName))

        XCTAssertNotNil(SemanticModelLocator.resolveTextModelURL(in: tmpDir))
        // Full multimodal resolve still reports missing mmproj.
        XCTAssertFalse(SemanticModelLocator.resolve(in: tmpDir).isReady)
    }
}
