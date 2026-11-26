import Foundation
import XCTest
@testable import QuickSpotCore

extension OCRRecoveryTests {
    // MARK: - ImageFolderCrawler & IndexSettingsStore Excluded Folders

    func testFolderCrawlerInspectSingleFileAndExcludedFolderPersistence() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("quickspot-crawler-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        defer { try? fm.removeItem(at: base) }

        let root = base.appendingPathComponent("WatchedRoot", isDirectory: true)
        let excludedSub = root.appendingPathComponent("PrivateExcluded", isDirectory: true)
        let nodeModules = root.appendingPathComponent("node_modules", isDirectory: true)
        let outside = base.appendingPathComponent("OutsideRoot", isDirectory: true)

        for dir in [root, excludedSub, nodeModules, outside] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let validPNG = root.appendingPathComponent("invoice.png")
        let tinyPNG = root.appendingPathComponent("tiny.png")
        let validPDF = root.appendingPathComponent("contract.pdf")
        let ignoredText = root.appendingPathComponent("readme.txt")
        let excludedPNG = excludedSub.appendingPathComponent("secret.png")
        let nodeModPNG = nodeModules.appendingPathComponent("asset.png")
        let outsidePNG = outside.appendingPathComponent("external.png")

        let bigImageBytes = Data(repeating: 0x41, count: 5_000)
        let bigPDFBytes = Data(repeating: 0x42, count: 2_048)
        try bigImageBytes.write(to: validPNG)
        try Data(repeating: 0x41, count: 512).write(to: tinyPNG)
        try bigPDFBytes.write(to: validPDF)
        try Data(repeating: 0x43, count: 5_000).write(to: ignoredText)
        try bigImageBytes.write(to: excludedPNG)
        try bigImageBytes.write(to: nodeModPNG)
        try bigImageBytes.write(to: outsidePNG)

        let roots = [root.path]
        let excluded = [excludedSub.path]

        let inspectedPNG = ImageFolderCrawler.inspectSingleFile(
            at: validPNG.path, allowedRoots: roots, excludedPaths: excluded
        )
        XCTAssertEqual(inspectedPNG?.url.path, validPNG.path)
        XCTAssertEqual(inspectedPNG?.size, 5_000)

        let inspectedPDF = ImageFolderCrawler.inspectSingleFile(
            at: validPDF.path, allowedRoots: roots, excludedPaths: excluded
        )
        XCTAssertEqual(inspectedPDF?.url.path, validPDF.path)

        XCTAssertNil(ImageFolderCrawler.inspectSingleFile(at: tinyPNG.path, allowedRoots: roots, excludedPaths: excluded))
        XCTAssertNil(ImageFolderCrawler.inspectSingleFile(at: ignoredText.path, allowedRoots: roots, excludedPaths: excluded))
        XCTAssertNil(ImageFolderCrawler.inspectSingleFile(at: excludedPNG.path, allowedRoots: roots, excludedPaths: excluded))
        XCTAssertNil(ImageFolderCrawler.inspectSingleFile(at: nodeModPNG.path, allowedRoots: roots, excludedPaths: excluded))
        XCTAssertNil(ImageFolderCrawler.inspectSingleFile(at: outsidePNG.path, allowedRoots: roots, excludedPaths: excluded))

        let crawledPaths = Set(ImageFolderCrawler.crawl(folders: roots, excludedPaths: excluded).map(\.url.path))
        XCTAssertEqual(crawledPaths, Set([validPNG.path, validPDF.path]))

        // IndexSettingsStore excludedFolders persistence & deduplication
        let suite = "QuickSpotExcludedSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settingsStore = IndexSettingsStore(defaults: defaults)
        XCTAssertEqual(settingsStore.load().excludedFolders, [])

        _ = settingsStore.addExcludedFolder(excludedSub.path)
        let afterDup = settingsStore.addExcludedFolder(excludedSub.path + "/")
        XCTAssertEqual(afterDup.excludedFolders, [excludedSub.path])

        let reloadedStore = IndexSettingsStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.load().excludedFolders, [excludedSub.path])

        let afterRemove = reloadedStore.removeExcludedFolder(excludedSub.path)
        XCTAssertEqual(afterRemove.excludedFolders, [])
        XCTAssertEqual(settingsStore.load().excludedFolders, [])
    }

    // MARK: - ImageOCRIndexer.searchAsync & Calibrated Score Range

    func testImageOCRIndexerSearchAsyncAndCalibratedScoreRange() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("quickspot-indexer-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("ocr.sqlite")
        let suite = "QuickSpotIndexerSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let recentPNG = tempDir.appendingPathComponent("fatura_ocak.png")
        let oldPDF = tempDir.appendingPathComponent("arsiv_belge.pdf")
        try Data("png".utf8).write(to: recentPNG)
        try Data("pdf".utf8).write(to: oldPDF)

        let now = Date().timeIntervalSince1970
        let store = ImageOCRStore(databaseURL: dbURL)
        let textA = "Fatura No 4242 Toplam 1.500 TL"
        let textB = "Fatura No 4242 Eski Arşiv Kaydı"
        store.upsert(
            path: recentPNG.path,
            name: recentPNG.lastPathComponent,
            mtime: now - 60,
            size: 5000,
            rawText: textA,
            foldedText: VisionTextExtractor.normalizeForSearch(textA),
            status: 1
        )
        store.upsert(
            path: oldPDF.path,
            name: oldPDF.lastPathComponent,
            mtime: now - 90 * 86_400,
            size: 5000,
            rawText: textB,
            foldedText: VisionTextExtractor.normalizeForSearch(textB),
            status: 1
        )

        let settingsStore = IndexSettingsStore(defaults: defaults)
        settingsStore.save(IndexSettings(folders: [tempDir.path], indexOnBattery: false, isOCREnabled: true))

        let indexer = ImageOCRIndexer(store: store, settingsStore: settingsStore)
        let hits = await indexer.searchAsync(query: "fatura 4242")

        XCTAssertEqual(hits.count, 2)
        for hit in hits {
            XCTAssertGreaterThanOrEqual(hit.score, 480)
            XCTAssertLessThanOrEqual(hit.score, 710)
            XCTAssertEqual(hit.matchSource, .ocrContent)
        }
        XCTAssertEqual(hits.first?.title, "fatura_ocak.png")
        XCTAssertGreaterThan(hits[0].score, hits[1].score)

        let imgOnly = await indexer.searchAsync(query: "fatura 4242", filter: .imagesOnly)
        XCTAssertEqual(imgOnly.map(\.title), ["fatura_ocak.png"])

        let pdfOnly = await indexer.searchAsync(query: "fatura 4242", filter: .pdfOnly)
        XCTAssertEqual(pdfOnly.map(\.title), ["arsiv_belge.pdf"])

        let foldersOnly = await indexer.searchAsync(query: "fatura 4242", filter: .foldersOnly)
        XCTAssertTrue(foldersOnly.isEmpty)

        let appsOnly = await indexer.searchAsync(query: "fatura 4242", filter: .appsOnly)
        XCTAssertTrue(appsOnly.isEmpty)

        let fullText = await indexer.fullTextAsync(forPath: recentPNG.path)
        XCTAssertEqual(fullText, textA)

        // Boundary checks on calibratedOCRScore
        let maxBound = ImageOCRIndexer.calibratedOCRScore(
            rankIndex: 0, mtime: now, now: now, fileName: "fatura.png", queryTokens: ["fatura"]
        )
        let minBound = ImageOCRIndexer.calibratedOCRScore(
            rankIndex: 50, mtime: 0, now: now, fileName: "other.png", queryTokens: ["fatura"]
        )
        XCTAssertEqual(maxBound, 710)
        XCTAssertEqual(minBound, 480)
    }
}
