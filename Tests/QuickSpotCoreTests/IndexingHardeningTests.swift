import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import QuickSpotCore

private final class CountingMockSemanticProvider: SemanticEmbeddingProvider, @unchecked Sendable {
    let modelIdentifier: String = "mock-hardening:4d"
    let dimension: Int = 4
    let status: SemanticModelStatus
    let validVectors: [String: [Float]]

    private let lock = NSLock()
    private var _embedCalls = 0
    private var _releaseCalls = 0
    private var _unloadCalls = 0

    var embedCalls: Int { lock.lock(); defer { lock.unlock() }; return _embedCalls }
    var releaseCalls: Int { lock.lock(); defer { lock.unlock() }; return _releaseCalls }
    var unloadCalls: Int { lock.lock(); defer { lock.unlock() }; return _unloadCalls }

    init(status: SemanticModelStatus, validVectors: [String: [Float]]) {
        self.status = status
        self.validVectors = validVectors
    }

    func modelStatus() async -> SemanticModelStatus { status }

    func embedQuery(_ text: String) async throws -> [Float] {
        [1, 0, 0, 0]
    }

    func embedImages(_ urls: [URL]) async throws -> [(url: URL, vector: [Float])] {
        lock.withLock { _embedCalls += 1 }
        return urls.compactMap { url in
            guard let vec = validVectors[url.lastPathComponent] else { return nil }
            return (url, vec)
        }
    }

    func releaseImageEncoder() async {
        lock.withLock { _releaseCalls += 1 }
    }

    func unloadAll() async {
        lock.withLock { _unloadCalls += 1 }
    }
}

final class IndexingHardeningTests: XCTestCase {
    func testOCRSQLKindFilteringDoesNotDropImagesBehindManyPDFs() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("quickspot-kindfilter-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let store = ImageOCRStore(databaseURL: tempDir.appendingPathComponent("ocr.sqlite"))
        let now = Date().timeIntervalSince1970

        // Insert 40 PDFs with stronger keyword density than 3 images so post-filtering on limit*3 would have returned 0 images.
        for i in 1...40 {
            let pdfURL = tempDir.appendingPathComponent("doc_\(i).pdf")
            try Data("pdf".utf8).write(to: pdfURL)
            let text = "fatura fatura fatura belge \(i)"
            store.upsert(
                path: pdfURL.path,
                name: pdfURL.lastPathComponent,
                mtime: now - Double(i),
                size: 2048,
                rawText: text,
                foldedText: VisionTextExtractor.normalizeForSearch(text),
                status: ImageOCRStore.statusIndexed
            )
        }
        for i in 1...3 {
            let pngURL = tempDir.appendingPathComponent("shot_\(i).png")
            try Data("png".utf8).write(to: pngURL)
            let text = "ekran goruntusu fatura \(i)"
            store.upsert(
                path: pngURL.path,
                name: pngURL.lastPathComponent,
                mtime: now - 1000 - Double(i),
                size: 5000,
                rawText: text,
                foldedText: VisionTextExtractor.normalizeForSearch(text),
                status: ImageOCRStore.statusIndexed
            )
        }

        let suite = "QuickSpotKindFilter-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settingsStore = IndexSettingsStore(defaults: defaults)
        settingsStore.save(IndexSettings(folders: [tempDir.path], indexOnBattery: true, isOCREnabled: true))

        let indexer = ImageOCRIndexer(store: store, settingsStore: settingsStore)
        let imgHits = await indexer.searchAsync(query: "fatura", filter: .imagesOnly, limit: 10)
        XCTAssertEqual(Set(imgHits.map(\.title)), Set(["shot_1.png", "shot_2.png", "shot_3.png"]))
        XCTAssertEqual(store.stats(), OCRStoreStats(indexedCount: 43, withTextCount: 43))
    }

    func testOCRStoreFailureRetryBoundingTargetedLookupAndEscapedFolderPrune() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("quickspot-ocr-hard-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let store = ImageOCRStore(databaseURL: tempDir.appendingPathComponent("ocr.sqlite"))
        let corruptPath = tempDir.appendingPathComponent("bad.png").path
        store.recordFailure(path: corruptPath, name: "bad.png", mtime: 500, size: 6000)
        store.recordFailure(path: corruptPath, name: "bad.png", mtime: 500, size: 6000)

        let targeted = store.existingRecords(forPaths: [corruptPath, "/nonexistent/path.png"])
        XCTAssertEqual(targeted.count, 1)
        XCTAssertEqual(targeted[corruptPath]?.status, ImageOCRStore.statusFailed)
        XCTAssertEqual(targeted[corruptPath]?.retryCount, 2)
        XCTAssertEqual(store.stats(), OCRStoreStats(indexedCount: 0, withTextCount: 0))

        // Resetting empty/failed images restores failed rows to pending (status=0, retryCount=0).
        store.resetEmptyImages()
        let afterReset = store.existingRecords(forPaths: [corruptPath])
        XCTAssertEqual(afterReset[corruptPath]?.status, ImageOCRStore.statusPending)
        XCTAssertEqual(afterReset[corruptPath]?.retryCount, 0)

        // Escaped LIKE prefix deletion must only remove matching folder, not SQL wildcard siblings.
        let specialFolder = tempDir.appendingPathComponent("100%_private").path
        let siblingFolder = tempDir.appendingPathComponent("100X_private").path
        store.upsert(path: "\(specialFolder)/a.png", name: "a.png", mtime: 10, size: 5000, rawText: "secret", foldedText: "secret")
        store.upsert(path: "\(siblingFolder)/b.png", name: "b.png", mtime: 10, size: 5000, rawText: "public", foldedText: "public")

        store.deleteUnderFolder(specialFolder)
        XCTAssertTrue(store.search(query: "secret").isEmpty)
        XCTAssertEqual(store.search(query: "public").map(\.fileName), ["b.png"])
    }

    func testSemanticVectorStoreBatchIncrementalMatrixFailuresAndFolderPrune() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("quickspot-sem-hard-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let store = SemanticVectorStore(databaseURL: tempDir.appendingPathComponent("sem.sqlite"))
        let keepDir = tempDir.appendingPathComponent("Keep").path
        let dropDir = tempDir.appendingPathComponent("Drop_100%").path

        store.upsert(path: "\(keepDir)/a.jpg", name: "a.jpg", mtime: 100, size: 5000, modelID: "m1", vector: [1, 0, 0, 0])
        // Warm in-memory matrix before testing incremental batch update.
        XCTAssertEqual(store.search(queryVector: [1, 0, 0, 0], modelID: "m1").map(\.fileName), ["a.jpg"])

        store.upsertBatch([
            SemanticVectorUpsert(path: "\(keepDir)/a.jpg", name: "a.jpg", mtime: 110, size: 5000, modelID: "m1", vector: [0, 1, 0, 0]),
            SemanticVectorUpsert(path: "\(dropDir)/b.jpg", name: "b.jpg", mtime: 120, size: 5000, modelID: "m1", vector: [0, 0, 1, 0])
        ])

        XCTAssertEqual(store.search(queryVector: [0, 1, 0, 0], modelID: "m1", minSimilarity: 0.9).map(\.fileName), ["a.jpg"])
        XCTAssertEqual(store.search(queryVector: [0, 0, 1, 0], modelID: "m1", minSimilarity: 0.9).map(\.fileName), ["b.jpg"])

        let badPath = "\(keepDir)/corrupt.jpg"
        store.recordFailures([(path: badPath, name: "corrupt.jpg", mtime: 50, size: 5000)], modelID: "m1")
        store.recordFailures([(path: badPath, name: "corrupt.jpg", mtime: 50, size: 5000)], modelID: "m1")
        let targeted = store.existingEntries(forPaths: [badPath, "\(dropDir)/b.jpg"])
        XCTAssertEqual(targeted[badPath]?.status, SemanticVectorStore.statusFailed)
        XCTAssertEqual(targeted[badPath]?.retryCount, 2)
        // Failed entries must not inflate indexed count.
        XCTAssertEqual(store.count(forModelID: "m1"), 2)

        store.deleteUnderFolder(dropDir)
        XCTAssertEqual(store.count(forModelID: "m1"), 1)
        XCTAssertTrue(store.search(queryVector: [0, 0, 1, 0], modelID: "m1", minSimilarity: 0.9).isEmpty)
        XCTAssertEqual(store.search(queryVector: [0, 1, 0, 0], modelID: "m1", minSimilarity: 0.9).map(\.fileName), ["a.jpg"])
    }

    func testCrawlerUnifiedIgnorePhotosLibraryCancellationAndLongestRoot() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("quickspot-crawl-hard-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        defer { try? fm.removeItem(at: base) }

        let deepRoot = base.appendingPathComponent("a/b/c/d/e/f", isDirectory: true)
        try fm.createDirectory(at: deepRoot, withIntermediateDirectories: true)
        let deepImage = deepRoot.appendingPathComponent("deep.png")
        try Data(repeating: 0x55, count: 5_000).write(to: deepImage)

        // Unified event path ignore rejects Photos Library, build outputs, and excluded folders.
        XCTAssertTrue(ImageFolderCrawler.shouldIgnoreEventPath(
            "\(base.path)/Photos Library.photoslibrary/resources/derivatives/1.jpeg",
            watchedRoots: [base.path]
        ))
        XCTAssertTrue(ImageFolderCrawler.shouldIgnoreEventPath(
            "\(base.path)/project/target/debug/icon.png",
            watchedRoots: [base.path]
        ))
        XCTAssertTrue(ImageFolderCrawler.shouldIgnoreEventPath(
            "\(base.path)/app/dist/banner.png",
            watchedRoots: [base.path]
        ))
        XCTAssertFalse(ImageFolderCrawler.shouldIgnoreEventPath(
            "\(base.path)/Screenshots/receipt.png",
            watchedRoots: [base.path]
        ))

        // Immediate cooperative cancellation returns empty without traversing.
        let cancelled = ImageFolderCrawler.crawl(folders: [deepRoot.path], shouldCancel: { true })
        XCTAssertTrue(cancelled.isEmpty)

        // Longest-matching root allows depth-7 file under `base` when `deepRoot` is explicitly added.
        let found = ImageFolderCrawler.inspectSingleFile(
            at: deepImage.path,
            allowedRoots: [base.path, deepRoot.path],
            excludedPaths: []
        )
        XCTAssertEqual(found?.url.path, deepImage.path)
    }

    func testCoordinatorSingleCrawlSequentialIndexingPoisonPillAndBatteryPrune() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("quickspot-coord-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        let watchedDir = tempDir.appendingPathComponent("Watched", isDirectory: true)
        try fm.createDirectory(at: watchedDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // Render a valid PNG with text + write a corrupt PNG.
        let goodPNG = watchedDir.appendingPathComponent("good.png")
        let badPNG = watchedDir.appendingPathComponent("corrupt.png")
        try writeRenderedPNG(text: "INVOICE 7788", to: goodPNG)
        try Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: UInt8(0xFF), count: 5_000)).write(to: badPNG)

        let suite = "QuickSpotCoord-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let folderStore = IndexSettingsStore(defaults: defaults)
        folderStore.save(IndexSettings(folders: [watchedDir.path], indexOnBattery: false, isOCREnabled: true))
        let semSettings = SemanticSettingsStore(defaults: defaults)
        semSettings.save(SemanticSettings(isEnabled: true, customModelsDirectory: nil))

        let ocrStore = ImageOCRStore(databaseURL: tempDir.appendingPathComponent("ocr.sqlite"))
        let semStore = SemanticVectorStore(databaseURL: tempDir.appendingPathComponent("sem.sqlite"))
        let readyStatus = SemanticModelStatus.ready(
            textURL: tempDir.appendingPathComponent("t.gguf"),
            mmprojURL: tempDir.appendingPathComponent("m.gguf"),
            directory: tempDir
        )
        let mockProvider = CountingMockSemanticProvider(
            status: readyStatus,
            validVectors: ["good.png": [1, 0, 0, 0]]
        )

        // Simulate on-battery blocker; force:true still runs, while pruneFolder must work even while blocked.
        let batteryBlocker: @Sendable () -> String? = { "On battery" }
        let ocrIndexer = ImageOCRIndexer(store: ocrStore, settingsStore: folderStore, blockerProvider: batteryBlocker)
        let semIndexer = SemanticImageIndexer(
            store: semStore,
            engine: mockProvider,
            folderSettingsStore: folderStore,
            semanticSettingsStore: semSettings,
            blockerProvider: batteryBlocker
        )
        let coordinator = IndexingCoordinator(
            ocrIndexer: ocrIndexer,
            semanticIndexer: semIndexer,
            folderSettingsStore: folderStore,
            semanticSettingsStore: semSettings,
            blockerProvider: batteryBlocker
        )

        coordinator.startPass(force: true)

        // Wait up to 5 seconds for both stages (OCR -> Semantic) to finish.
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if ocrStore.stats().indexedCount == 1 && semStore.count(forModelID: mockProvider.modelIdentifier) == 1 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(ocrStore.stats().indexedCount, 1)
        XCTAssertEqual(semStore.count(forModelID: mockProvider.modelIdentifier), 1)
        XCTAssertEqual(ocrStore.existingRecords(forPaths: [badPNG.path])[badPNG.path]?.status, ImageOCRStore.statusFailed)
        XCTAssertEqual(semStore.existingEntries(forPaths: [badPNG.path])[badPNG.path]?.status, SemanticVectorStore.statusFailed)

        // Pruning a removed folder must purge BOTH databases immediately despite active battery blocker.
        coordinator.pruneFolder(watchedDir.path)
        XCTAssertEqual(ocrStore.stats().indexedCount, 0)
        XCTAssertEqual(semStore.count(forModelID: mockProvider.modelIdentifier), 0)

        // Disabling semantic search via stopAndUnload cancels and unloads cleanly.
        semIndexer.stopAndUnload()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertGreaterThanOrEqual(mockProvider.unloadCalls, 1)
    }

    func testLockedPDFSkipsOCRWithoutFailing() throws {
        let pdfURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickspot-locked-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 180)
        let auxInfo: [CFString: Any] = [
            kCGPDFContextUserPassword: "secret-user-pass",
            kCGPDFContextOwnerPassword: "secret-owner-pass"
        ]
        guard let ctx = CGContext(pdfURL as CFURL, mediaBox: &mediaBox, auxInfo as CFDictionary) else {
            XCTFail("Failed to create encrypted PDF")
            return
        }
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()

        switch PDFTextExtractor.extractTextResult(from: pdfURL) {
        case .success(let text):
            XCTAssertEqual(text, "")
        case .failure(let error):
            XCTFail("Locked PDF should gracefully return empty text instead of error: \(error)")
        }
    }

    private func writeRenderedPNG(text: String, to url: URL) throws {
        let width = 420
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
        NSString(string: text).draw(
            at: NSPoint(x: 24, y: 44),
            withAttributes: [.font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.black]
        )
        NSGraphicsContext.restoreGraphicsState()
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
