import Foundation
import XCTest
@testable import QuickSpotCore

private struct MockSemanticProvider: SemanticEmbeddingProvider {
    let modelIdentifier: String = "mock-gemma-test:4d"
    let dimension: Int = 4
    let status: SemanticModelStatus
    let imageVectors: [String: [Float]]
    let queryVectors: [String: [Float]]

    func modelStatus() async -> SemanticModelStatus { status }

    func embedQuery(_ text: String) async throws -> [Float] {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let vec = queryVectors[key] { return vec }
        return [0, 0, 0, 1]
    }

    func embedImages(_ urls: [URL]) async throws -> [(url: URL, vector: [Float])] {
        urls.compactMap { url in
            guard let vec = imageVectors[url.lastPathComponent] else { return nil }
            return (url, vec)
        }
    }

    func releaseImageEncoder() async {}
    func unloadAll() async {}
}

final class SemanticSearchTests: XCTestCase {
    func testSemanticSettingsAndModelLocatorMissingAndReady() throws {
        let suite = "QuickSpotSemanticTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settingsStore = SemanticSettingsStore(defaults: defaults)
        XCTAssertEqual(settingsStore.load(), SemanticSettings(isEnabled: true, customModelsDirectory: nil))

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickspot-models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        settingsStore.save(SemanticSettings(isEnabled: false, customModelsDirectory: tmpDir.path + "/"))
        let loaded = settingsStore.load()
        XCTAssertFalse(loaded.isEnabled)
        XCTAssertEqual(loaded.customModelsDirectory, tmpDir.path)

        let missingStatus = SemanticModelLocator.resolve(in: tmpDir)
        XCTAssertFalse(missingStatus.isReady)
        if case .missing(_, let missingFiles) = missingStatus {
            XCTAssertEqual(missingFiles.count, 2)
        } else {
            XCTFail("Expected missing status")
        }

        // Reject non-GGUF garbage files even when larger than 1 MB (e.g. HTML 404 or corrupted downloads).
        let invalidDummy = Data(repeating: 0x47, count: 1_100_000)
        let textFile = tmpDir.appendingPathComponent(SemanticModelLocator.textModelFileName)
        let mmprojFile = tmpDir.appendingPathComponent(SemanticModelLocator.mmprojModelFileName)
        try invalidDummy.write(to: textFile)
        try invalidDummy.write(to: mmprojFile)
        XCTAssertFalse(SemanticModelLocator.resolve(in: tmpDir).isReady)

        // Write valid GGUF v3 header ("GGUF" + LE UInt32(3)) >1MB files to simulate present GGUF weights.
        var validGGUF = Data([0x47, 0x47, 0x55, 0x46, 0x03, 0x00, 0x00, 0x00])
        validGGUF.append(Data(repeating: 0x00, count: 1_100_000))
        try validGGUF.write(to: textFile)
        try validGGUF.write(to: mmprojFile)

        let readyStatus = SemanticModelLocator.resolve(in: tmpDir)
        XCTAssertTrue(readyStatus.isReady)
    }

    func testVectorStorePersistenceAccelerateSearchAndCleanup() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickspot-vec-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-shm"))
        }

        let store = SemanticVectorStore(databaseURL: dbURL)
        store.upsert(path: "/tmp/a.jpg", name: "a.jpg", mtime: 100, size: 5000, modelID: "m1", vector: [1, 0, 0, 0])
        store.upsert(path: "/tmp/b.jpg", name: "b.jpg", mtime: 200, size: 6000, modelID: "m1", vector: [0, 1, 0, 0])
        store.upsert(path: "/tmp/c.jpg", name: "c.jpg", mtime: 300, size: 7000, modelID: "m1", vector: [0.8, 0.6, 0, 0])
        XCTAssertEqual(store.count(forModelID: "m1"), 3)

        let hits = store.search(queryVector: [1, 0, 0, 0], modelID: "m1", limit: 5, minSimilarity: 0.5)
        XCTAssertEqual(hits.map(\.fileName), ["a.jpg", "c.jpg"])
        XCTAssertEqual(hits[0].similarity, 1.0, accuracy: 0.0001)
        XCTAssertEqual(hits[1].similarity, 0.8, accuracy: 0.0001)

        store.delete(paths: ["/tmp/a.jpg"])
        XCTAssertEqual(store.count(forModelID: "m1"), 2)

        store.deleteMissing(keeping: ["/tmp/c.jpg"])
        XCTAssertEqual(store.count(forModelID: "m1"), 1)

        // Verify persistence across reopen
        let reopened = SemanticVectorStore(databaseURL: dbURL)
        XCTAssertEqual(reopened.count(forModelID: "m1"), 1)
        let reopenedHits = reopened.search(queryVector: [0.8, 0.6, 0, 0], modelID: "m1", limit: 5, minSimilarity: 0.9)
        XCTAssertEqual(reopenedHits.map(\.fileName), ["c.jpg"])

        reopened.clearAll()
        XCTAssertEqual(reopened.count(forModelID: "m1"), 0)
    }

    func testTurkishQueryRestorerRestoresDiacriticsWithoutBreakingEnglish() {
        let validTurkish: Set<String> = [
            "kopek", "köpek", "beyaz", "araba",
            "çocuk", "çoçuk", "kırmızı", "gülen",
            "dog", "cat", "çat", "safari"
        ]
        let validEnglish: Set<String> = ["dog", "cat", "safari"]
        let mockGuesses: [String: [String]] = [
            // Mirrors macOS 15 AppleSpell returning the 2-edit typo before the 1-edit valid word.
            "cocuk": ["çoçuk", "çocuk"],
            "gulen": ["gülen", "gelen"],
            "kirmizi": ["kimizi", "karmizi"]
        ]

        let isValid: (String, String) -> Bool = { word, lang in
            lang == "tr" ? validTurkish.contains(word) : validEnglish.contains(word)
        }
        let guesses: (String, String) -> [String] = { word, lang in
            lang == "tr" ? (mockGuesses[word] ?? []) : []
        }

        L10n.withLanguage(.tr) {
            XCTAssertEqual(TurkishQueryRestorer.restoredVariant(for: "kopek", isWordValid: isValid, guesses: guesses), "köpek")
            XCTAssertEqual(TurkishQueryRestorer.restoredVariant(for: "beyaz kopek", isWordValid: isValid, guesses: guesses), "beyaz köpek")
            XCTAssertEqual(TurkishQueryRestorer.restoredVariant(for: "cocuk", isWordValid: isValid, guesses: guesses), "çocuk")
            XCTAssertEqual(TurkishQueryRestorer.restoredVariant(for: "kirmizi araba", isWordValid: isValid, guesses: guesses), "kırmızı araba")
            XCTAssertEqual(TurkishQueryRestorer.restoredVariant(for: "gulen cocuk", isWordValid: isValid, guesses: guesses), "gülen çocuk")
            XCTAssertNil(TurkishQueryRestorer.restoredVariant(for: "köpek", isWordValid: isValid, guesses: guesses))
            XCTAssertNil(TurkishQueryRestorer.restoredVariant(for: "dog", isWordValid: isValid, guesses: guesses))
            XCTAssertNil(TurkishQueryRestorer.restoredVariant(for: "cat", isWordValid: isValid, guesses: guesses))
            XCTAssertNil(TurkishQueryRestorer.restoredVariant(for: "safari", isWordValid: isValid, guesses: guesses))

            // Even if guesses only proposes a 2-edit form (`çoçuk`), a valid 1-edit word (`çocuk`) must win.
            XCTAssertEqual(
                TurkishQueryRestorer.restoredVariant(
                    for: "cocuk",
                    isWordValid: isValid,
                    guesses: { word, lang in lang == "tr" && word == "cocuk" ? ["çoçuk"] : [] }
                ),
                "çocuk"
            )

            // Live NSSpellChecker sanity checks that remain stable across macOS 14/15/26 system dictionaries.
            if let liveKopek = TurkishQueryRestorer.restoredVariant(for: "kopek") {
                XCTAssertEqual(VisionTextExtractor.normalizeForSearch(liveKopek), "kopek")
            }
            XCTAssertNil(TurkishQueryRestorer.restoredVariant(for: "köpek"))
            XCTAssertNil(TurkishQueryRestorer.restoredVariant(for: "dog"))
            XCTAssertNil(TurkishQueryRestorer.restoredVariant(for: "cat"))
            XCTAssertNil(TurkishQueryRestorer.restoredVariant(for: "safari"))
        }
    }

    func testSemanticIndexerWithMockProviderAndRankerFusion() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("quickspot-sem-idx-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let imgWhiteDog = tempDir.appendingPathComponent("IMG_001.jpg")
        let imgBlackDog = tempDir.appendingPathComponent("IMG_002.jpg")
        let imgChild = tempDir.appendingPathComponent("IMG_003.jpg")
        let payload = Data(repeating: 0xFF, count: 5_000)
        try payload.write(to: imgWhiteDog)
        try payload.write(to: imgBlackDog)
        try payload.write(to: imgChild)

        let suite = "QuickSpotSemIdx-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let folderStore = IndexSettingsStore(defaults: defaults)
        folderStore.save(IndexSettings(folders: [tempDir.path], indexOnBattery: true, isOCREnabled: true))
        let semSettings = SemanticSettingsStore(defaults: defaults)
        semSettings.save(SemanticSettings(isEnabled: true, customModelsDirectory: nil))

        let readyStatus = SemanticModelStatus.ready(
            textURL: tempDir.appendingPathComponent("t.gguf"),
            mmprojURL: tempDir.appendingPathComponent("m.gguf"),
            directory: tempDir
        )
        let provider = MockSemanticProvider(
            status: readyStatus,
            imageVectors: [
                "IMG_001.jpg": [0.95, 0.31, 0.0, 0.0],
                "IMG_002.jpg": [0.10, 0.99, 0.0, 0.0],
                "IMG_003.jpg": [0.0, 0.0, 1.0, 0.0]
            ],
            queryVectors: [
                "beyaz kopek": [0.95, 0.31, 0.0, 0.0],
                "siyah kopek": [0.10, 0.99, 0.0, 0.0],
                "cocuk": [0.0, 0.0, 1.0, 0.0]
            ]
        )

        let store = SemanticVectorStore(databaseURL: tempDir.appendingPathComponent("sem.sqlite"))
        let now = Date().timeIntervalSince1970
        for url in [imgWhiteDog, imgBlackDog, imgChild] {
            let vec = try XCTUnwrap(provider.imageVectors[url.lastPathComponent])
            store.upsert(path: url.path, name: url.lastPathComponent, mtime: now, size: 5_000, modelID: provider.modelIdentifier, vector: vec)
        }

        let indexer = SemanticImageIndexer(
            store: store,
            engine: provider,
            folderSettingsStore: folderStore,
            semanticSettingsStore: semSettings,
            generalMinSimilarity: 0.4,
            imageFilterMinSimilarity: 0.3
        )

        let whiteHits = await indexer.searchAsync(query: "beyaz kopek")
        XCTAssertEqual(whiteHits.first?.title, "IMG_001.jpg")
        XCTAssertEqual(whiteHits.first?.matchSource, .semanticVisual)

        let blackHits = await indexer.searchAsync(query: "siyah kopek")
        XCTAssertEqual(blackHits.first?.title, "IMG_002.jpg")

        let childHits = await indexer.searchAsync(query: "cocuk")
        XCTAssertEqual(childHits.map(\.title), ["IMG_003.jpg"])

        // PDF/folder/app filters must never return visual image hits.
        let pdfOnly = await indexer.searchAsync(query: "cocuk", filter: .pdfOnly)
        XCTAssertTrue(pdfOnly.isEmpty)
        let foldersOnly = await indexer.searchAsync(query: "cocuk", filter: .foldersOnly)
        XCTAssertTrue(foldersOnly.isEmpty)

        // ResultRanker fuses filename + semantic visual hit without duplication.
        let nameHit = SearchItem(
            id: "file:\(imgChild.path)", title: imgChild.lastPathComponent, subtitle: "~",
            category: .file, iconPath: imgChild.path, score: 780,
            action: .openFile(imgChild), previewURL: imgChild, matchSource: .name
        )
        let merged = ResultRanker.mergeDeduplicatingFiles(ocr: childHits, files: [nameHit])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].score, 850)
        XCTAssertNotNil(merged[0].matchedSnippet)
    }

    /// Runs live EmbeddingGemma 2 Metal inference against real downloaded photos when weights & samples exist locally.
    func testRealEmbeddingGemma2MultilingualVisualSearchCalibration() async throws {
        let modelStatus = SemanticModelLocator.resolve()
        guard modelStatus.isReady else {
            throw XCTSkip("Local EmbeddingGemma 2 weights not present; skipping live Metal test.")
        }

        let sampleDirPath = ProcessInfo.processInfo.environment["QUICKSPOT_VISUAL_SAMPLES_DIR"] ?? ""
        guard !sampleDirPath.isEmpty, FileManager.default.fileExists(atPath: sampleDirPath) else {
            throw XCTSkip("QUICKSPOT_VISUAL_SAMPLES_DIR not set; skipping live sample photo matrix test.")
        }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("quickspot-live-gemma-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // Copy samples with completely NEUTRAL filenames so filename cannot help search!
        let sampleDir = URL(fileURLWithPath: sampleDirPath, isDirectory: true)
        let sourceFiles = try fm.contentsOfDirectory(at: sampleDir, includingPropertiesForKeys: nil)
            .filter { VisionTextExtractor.isSupportedImage($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var neutralToLabel: [String: String] = [:]
        var neutralURLs: [URL] = []
        for (idx, src) in sourceFiles.enumerated() {
            let neutralName = String(format: "IMG_%03d.%@", idx + 1, src.pathExtension.lowercased())
            let dst = tempDir.appendingPathComponent(neutralName)
            try fm.copyItem(at: src, to: dst)
            neutralToLabel[neutralName] = src.deletingPathExtension().lastPathComponent
            neutralURLs.append(dst)
        }

        let engine = SemanticEmbeddingEngine(idleUnloadSeconds: 0)
        let store = SemanticVectorStore(databaseURL: tempDir.appendingPathComponent("live.sqlite"))
        let suite = "QuickSpotLiveSemantic-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let folderStore = IndexSettingsStore(defaults: defaults)
        folderStore.save(IndexSettings(folders: [tempDir.path], indexOnBattery: true, isOCREnabled: true))
        let semSettings = SemanticSettingsStore(defaults: defaults)
        semSettings.save(SemanticSettings(isEnabled: true, customModelsDirectory: nil))

        let t0 = Date()
        let embedded = try await engine.embedImages(neutralURLs)
        let embedElapsed = Date().timeIntervalSince(t0)
        print(String(format: "[CALIBRATION] Embedded %d images in %.2fs", embedded.count, embedElapsed))
        XCTAssertEqual(embedded.count, neutralURLs.count)

        let now = Date().timeIntervalSince1970
        for (url, vec) in embedded {
            store.upsert(path: url.path, name: url.lastPathComponent, mtime: now, size: 10000, modelID: engine.modelIdentifier, vector: vec)
        }
        await engine.releaseImageEncoder()

        let indexer = SemanticImageIndexer(
            store: store,
            engine: engine,
            folderSettingsStore: folderStore,
            semanticSettingsStore: semSettings
        )

        func labels(for query: String, filter: SearchKindFilter? = nil) async -> [String] {
            let items = await indexer.searchAsync(query: query, filter: filter, limit: 8)
            return items.map { neutralToLabel[$0.title] ?? $0.title }
        }

        // 1. Color + breed/object discrimination (Turkish ASCII, Turkish diacritics, and English)
        let whiteAscii = await labels(for: "beyaz kopek")
        let whiteTr = await labels(for: "beyaz köpek")
        let whiteEn = await labels(for: "white dog")
        XCTAssertEqual(whiteAscii, ["white_dog"], "beyaz kopek returned: \(whiteAscii)")
        XCTAssertEqual(whiteTr, ["white_dog"], "beyaz köpek returned: \(whiteTr)")
        XCTAssertEqual(whiteEn, ["white_dog"], "white dog returned: \(whiteEn)")

        let blackAscii = await labels(for: "siyah kopek")
        let blackTr = await labels(for: "siyah köpek")
        let blackEn = await labels(for: "black dog")
        XCTAssertEqual(blackAscii, ["black_dog"], "siyah kopek returned: \(blackAscii)")
        XCTAssertEqual(blackTr, ["black_dog"], "siyah köpek returned: \(blackTr)")
        XCTAssertEqual(blackEn, ["black_dog"], "black dog returned: \(blackEn)")

        let brownAscii = await labels(for: "kahverengi kopek")
        let brownTr = await labels(for: "kahverengi köpek")
        let brownEn = await labels(for: "brown dog")
        XCTAssertEqual(brownAscii, ["brown_dog"], "kahverengi kopek returned: \(brownAscii)")
        XCTAssertEqual(brownTr, ["brown_dog"], "kahverengi köpek returned: \(brownTr)")
        XCTAssertEqual(brownEn, ["brown_dog"], "brown dog returned: \(brownEn)")

        // 2. General dog query returns all 3 dogs cleanly without text screenshot
        let allDogsTr = await labels(for: "köpek")
        XCTAssertEqual(Set(allDogsTr), Set(["white_dog", "black_dog", "brown_dog"]), "köpek returned: \(allDogsTr)")
        let dogsAscii = await labels(for: "kopek")
        XCTAssertTrue(dogsAscii.first?.hasSuffix("_dog") == true, "kopek returned: \(dogsAscii)")

        // 3. Child queries (Turkish ASCII, diacritics, phrase, English)
        let cocukAscii = await labels(for: "cocuk")
        let cocukTr = await labels(for: "çocuk")
        let childEn = await labels(for: "child")
        XCTAssertEqual(cocukAscii.first, "child", "cocuk returned: \(cocukAscii)")
        XCTAssertTrue(cocukAscii.contains("child_full"), "cocuk missing child_full: \(cocukAscii)")
        XCTAssertFalse(cocukAscii.contains("text_screenshot"), "cocuk leaked screenshot: \(cocukAscii)")
        XCTAssertEqual(Set(cocukTr), Set(["child", "child_full"]), "çocuk returned: \(cocukTr)")
        XCTAssertEqual(Set(childEn), Set(["child", "child_full"]), "child returned: \(childEn)")

        // 4. Other categories (cat, red car)
        let catHits = await labels(for: "kedi")
        XCTAssertEqual(catHits.first, "cat", "kedi returned: \(catHits)")
        let redCarHits = await labels(for: "kirmizi araba")
        XCTAssertEqual(redCarHits.first, "red_car", "kirmizi araba returned: \(redCarHits)")

        // 5. Negative controls must return ZERO false-positive visual hits!
        for negative in ["safari", "terminal", "fatura", "hesap makinesi", "uçak", "deniz plaj"] {
            let negHits = await labels(for: negative)
            XCTAssertTrue(negHits.isEmpty, "Negative query '\(negative)' leaked false positives: \(negHits)")
        }

        await engine.unloadAll()
    }

    /// Optional read-only verification against a copied real corpus DB (`QUICKSPOT_LIVE_DB_COPY`) with z-score active.
    func testRealLiveDatabaseCorpusQueries() async throws {
        guard let dbPath = ProcessInfo.processInfo.environment["QUICKSPOT_LIVE_DB_COPY"],
              !dbPath.isEmpty,
              FileManager.default.fileExists(atPath: dbPath),
              SemanticModelLocator.resolve().isReady else {
            throw XCTSkip("QUICKSPOT_LIVE_DB_COPY not set; skipping live corpus verification.")
        }

        let store = SemanticVectorStore(databaseURL: URL(fileURLWithPath: dbPath))
        let engine = SemanticEmbeddingEngine(idleUnloadSeconds: 0)
        let suite = "QuickSpotLiveCorpus-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let folderStore = IndexSettingsStore(defaults: defaults)
        let semSettings = SemanticSettingsStore(defaults: defaults)
        semSettings.save(SemanticSettings(isEnabled: true, customModelsDirectory: nil))

        let indexer = SemanticImageIndexer(
            store: store,
            engine: engine,
            folderSettingsStore: folderStore,
            semanticSettingsStore: semSettings
        )

        let queries = [
            "beyaz kopek", "beyaz köpek", "siyah kopek", "kahverengi kopek",
            "köpek", "kopek", "cocuk", "çocuk", "kedi", "kirmizi araba", "kırmızı araba",
            "safari", "terminal", "hesap makinesi"
        ]
        print("\n=== LIVE REAL CORPUS (\(store.count()) IMAGES) WITH HUBNESS REDUCTION + TURKISH RESTORATION ===")
        for q in queries {
            let hits = await indexer.searchAsync(query: q, filter: nil, limit: 5)
            let summary = hits.map { "\($0.title)(\($0.score))" }.joined(separator: ", ")
            print(String(format: "%-18s -> %@", (q as NSString).utf8String!, summary.isEmpty ? "[]" : summary))
        }
        await engine.unloadAll()
    }
}
