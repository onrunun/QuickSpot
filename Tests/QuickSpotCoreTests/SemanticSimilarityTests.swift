import Foundation
import XCTest
@testable import QuickSpotCore

private final class TrackingSimilarityProvider: SemanticEmbeddingProvider, @unchecked Sendable {
    let modelIdentifier: String = "mock-sim-test:4d"
    let dimension: Int = 4
    let status: SemanticModelStatus
    let textReady: Bool
    let imageVectors: [String: [Float]]
    let queryVectors: [String: [Float]]
    let docVectors: [[Float]]

    private let lock = NSLock()
    private(set) var embedImageCallCount = 0
    private(set) var embedQueryCallCount = 0
    private(set) var embedDocumentCallCount = 0

    init(
        status: SemanticModelStatus,
        textReady: Bool = true,
        imageVectors: [String: [Float]] = [:],
        queryVectors: [String: [Float]] = [:],
        docVectors: [[Float]] = []
    ) {
        self.status = status
        self.textReady = textReady
        self.imageVectors = imageVectors
        self.queryVectors = queryVectors
        self.docVectors = docVectors
    }

    func modelStatus() async -> SemanticModelStatus { status }
    func isTextModelReady() async -> Bool { textReady }

    func embedQuery(_ text: String) async throws -> [Float] {
        lock.withLock { embedQueryCallCount += 1 }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return queryVectors[key] ?? [0, 0, 0, 1]
    }

    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        lock.withLock { embedDocumentCallCount += 1 }
        return Array(docVectors.prefix(texts.count))
    }

    func embedImages(_ urls: [URL]) async throws -> [(url: URL, vector: [Float])] {
        lock.withLock { embedImageCallCount += 1 }
        return urls.compactMap { url in
            guard let vec = imageVectors[url.lastPathComponent] else { return nil }
            return (url, vec)
        }
    }

    func releaseImageEncoder() async {}
    func unloadAll() async {}
}

final class SemanticSimilarityTests: XCTestCase {
    func testVectorStoreLookupAndSelfExclusion() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickspot-sim-vec-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-shm"))
        }

        let store = SemanticVectorStore(databaseURL: dbURL)
        store.upsert(path: "/tmp/a.jpg", name: "a.jpg", mtime: 100, size: 1000, modelID: "m1", vector: [1, 0, 0, 0])
        store.upsert(path: "/tmp/b.jpg", name: "b.jpg", mtime: 200, size: 1000, modelID: "m1", vector: [0.9, 0.4359, 0, 0])
        store.upsert(path: "/tmp/c.jpg", name: "c.jpg", mtime: 300, size: 1000, modelID: "m1", vector: [0, 1, 0, 0])

        // Cold SQLite read before matrix load
        let coldVec = try XCTUnwrap(store.vector(forPath: "/tmp/a.jpg", modelID: "m1", dimension: 4))
        XCTAssertEqual(coldVec, [1, 0, 0, 0])

        // Exclude self while searching; matrix becomes hot
        let result = store.searchWithStats(
            queryVector: coldVec,
            modelID: "m1",
            limit: 5,
            minSimilarity: 0.5,
            excludePath: "/tmp/a.jpg",
            applyHubness: false
        )
        XCTAssertEqual(result.corpusCount, 2)
        XCTAssertEqual(result.hits.map(\.fileName), ["b.jpg"])
        XCTAssertEqual(result.hits[0].similarity, 0.9, accuracy: 0.001)

        // Hot in-memory matrix read
        let hotVec = try XCTUnwrap(store.vector(forPath: "/tmp/b.jpg", modelID: "m1", dimension: 4))
        XCTAssertEqual(hotVec[0], 0.9, accuracy: 0.001)
    }

    func testIndexedAndOnTheFlyImageSimilarityWithHybridRefinement() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("quickspot-sim-img-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let anchorURL = tempDir.appendingPathComponent("car_anchor.jpg")
        let nightCarURL = tempDir.appendingPathComponent("car_night.jpg")
        let dayCarURL = tempDir.appendingPathComponent("car_day.jpg")
        let catURL = tempDir.appendingPathComponent("cat.jpg")
        let unindexedURL = tempDir.appendingPathComponent("unindexed_car.jpg")
        let payload = Data(repeating: 0xAB, count: 4_096)
        for url in [anchorURL, nightCarURL, dayCarURL, catURL, unindexedURL] {
            try payload.write(to: url)
        }

        let suite = "QuickSpotSimImg-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let semSettings = SemanticSettingsStore(defaults: defaults)
        semSettings.save(SemanticSettings(isEnabled: true, customModelsDirectory: nil))

        let readyStatus = SemanticModelStatus.ready(
            textURL: tempDir.appendingPathComponent("t.gguf"),
            mmprojURL: tempDir.appendingPathComponent("m.gguf"),
            directory: tempDir
        )
        // Anchor is [1, 0, 0, 0]. Both nightCar and dayCar share 0.85 similarity with anchor,
        // while nightCar aligns with +axis2 (night) and dayCar aligns with +axis3 (day).
        let provider = TrackingSimilarityProvider(
            status: readyStatus,
            textReady: true,
            imageVectors: [
                "unindexed_car.jpg": [0.98, 0.199, 0.0, 0.0]
            ],
            queryVectors: [
                "night": [0.0, 1.0, 0.0, 0.0],
                "day": [0.0, 0.0, 1.0, 0.0]
            ]
        )

        let store = SemanticVectorStore(databaseURL: tempDir.appendingPathComponent("img.sqlite"))
        let now = Date().timeIntervalSince1970
        store.upsert(path: anchorURL.path, name: anchorURL.lastPathComponent, mtime: now, size: 4096, modelID: provider.modelIdentifier, vector: [1.0, 0.0, 0.0, 0.0])
        store.upsert(path: nightCarURL.path, name: nightCarURL.lastPathComponent, mtime: now - 10, size: 4096, modelID: provider.modelIdentifier, vector: [0.85, 0.5268, 0.0, 0.0])
        store.upsert(path: dayCarURL.path, name: dayCarURL.lastPathComponent, mtime: now, size: 4096, modelID: provider.modelIdentifier, vector: [0.85, 0.0, 0.5268, 0.0])
        store.upsert(path: catURL.path, name: catURL.lastPathComponent, mtime: now, size: 4096, modelID: provider.modelIdentifier, vector: [0.0, 0.0, 0.0, 1.0])

        let indexer = SemanticImageIndexer(
            store: store,
            engine: provider,
            folderSettingsStore: IndexSettingsStore(defaults: defaults),
            semanticSettingsStore: semSettings
        )

        XCTAssertEqual(indexer.similarityTargetKind(for: anchorURL), .image)
        XCTAssertNil(indexer.similarityTargetKind(for: tempDir))

        // 1. Cached vector path: zero GPU image embedding calls, excludes self and orthogonal cat.
        let similar = await indexer.findSimilarAsync(to: anchorURL, kind: .image)
        XCTAssertEqual(similar.status, .ready)
        XCTAssertEqual(provider.embedImageCallCount, 0)
        XCTAssertEqual(Set(similar.items.map(\.title)), ["car_night.jpg", "car_day.jpg"])
        XCTAssertFalse(similar.items.contains(where: { $0.title == "car_anchor.jpg" }))
        XCTAssertFalse(similar.items.contains(where: { $0.title == "cat.jpg" }))

        // 2. Hybrid refinement with "night" promotes car_night.jpg to #1.
        let refinedNight = await indexer.findSimilarAsync(to: anchorURL, kind: .image, refinementQuery: "night")
        XCTAssertEqual(refinedNight.status, .ready)
        XCTAssertEqual(refinedNight.items.first?.title, "car_night.jpg")
        XCTAssertGreaterThanOrEqual(provider.embedQueryCallCount, 1)

        // 3. Hybrid refinement with "day" promotes car_day.jpg to #1.
        let refinedDay = await indexer.findSimilarAsync(to: anchorURL, kind: .image, refinementQuery: "day")
        XCTAssertEqual(refinedDay.status, .ready)
        XCTAssertEqual(refinedDay.items.first?.title, "car_day.jpg")

        // 4. Unindexed image falls back to on-the-fly embedding and finds indexed matches.
        let onTheFly = await indexer.findSimilarAsync(to: unindexedURL, kind: .image)
        XCTAssertEqual(onTheFly.status, .ready)
        XCTAssertEqual(provider.embedImageCallCount, 1)
        XCTAssertEqual(onTheFly.items.first?.title, "car_anchor.jpg")
    }

    func testDocumentCentroidSimilarityAndMissingModelHandling() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("quickspot-sim-doc-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let invoice1 = tempDir.appendingPathComponent("invoice_jan.pdf")
        let invoice2 = tempDir.appendingPathComponent("invoice_feb.pdf")
        let recipe = tempDir.appendingPathComponent("pasta_recipe.pdf")
        let unindexedPDF = tempDir.appendingPathComponent("new_contract.pdf")
        for url in [invoice1, invoice2, recipe, unindexedPDF] {
            try Data("PDF".utf8).write(to: url)
        }

        let suite = "QuickSpotSimDoc-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let semSettings = SemanticSettingsStore(defaults: defaults)
        semSettings.save(SemanticSettings(isEnabled: true, customModelsDirectory: nil))

        let missingStatus = SemanticModelStatus.missing(
            directory: tempDir,
            missingFiles: [SemanticModelLocator.textModelFileName, SemanticModelLocator.mmprojModelFileName]
        )
        let provider = TrackingSimilarityProvider(status: missingStatus, textReady: false)

        let docStore = SemanticDocumentStore(databaseURL: tempDir.appendingPathComponent("doc.sqlite"))
        let ocrStore = ImageOCRStore(databaseURL: tempDir.appendingPathComponent("ocr.sqlite"))
        let now = Date().timeIntervalSince1970

        // invoice1 has two chunks whose normalized centroid points closely along [1, 0, 0, 0]
        docStore.upsertDocumentChunks(
            path: invoice1.path, name: invoice1.lastPathComponent, kind: .pdf,
            mtime: now, size: 100, modelID: provider.modelIdentifier,
            chunks: [
                (SemanticTextChunk(index: 0, embedInput: "a", excerpt: "January invoice total"), [0.98, 0.199, 0, 0]),
                (SemanticTextChunk(index: 1, embedInput: "b", excerpt: "Tax breakdown"), [0.98, -0.199, 0, 0])
            ]
        )
        docStore.upsertDocumentChunks(
            path: invoice2.path, name: invoice2.lastPathComponent, kind: .pdf,
            mtime: now, size: 100, modelID: provider.modelIdentifier,
            chunks: [
                (SemanticTextChunk(index: 0, embedInput: "c", excerpt: "February billing statement"), [0.95, 0.3122, 0, 0])
            ]
        )
        docStore.upsertDocumentChunks(
            path: recipe.path, name: recipe.lastPathComponent, kind: .pdf,
            mtime: now, size: 100, modelID: provider.modelIdentifier,
            chunks: [
                (SemanticTextChunk(index: 0, embedInput: "d", excerpt: "Boil salted water"), [0, 0, 1, 0])
            ]
        )

        let docIndexer = SemanticDocumentIndexer(
            documentStore: docStore,
            ocrStore: ocrStore,
            engine: provider
        )
        let imageIndexer = SemanticImageIndexer(
            store: SemanticVectorStore(databaseURL: tempDir.appendingPathComponent("img.sqlite")),
            documentIndexer: docIndexer,
            engine: provider,
            folderSettingsStore: IndexSettingsStore(defaults: defaults),
            semanticSettingsStore: semSettings
        )

        XCTAssertEqual(imageIndexer.similarityTargetKind(for: invoice1), .document)

        // Indexed PDF similarity works instantly even when live models are unavailable!
        let similarDocs = await imageIndexer.findSimilarAsync(to: invoice1, kind: .document)
        XCTAssertEqual(similarDocs.status, .ready)
        XCTAssertEqual(similarDocs.items.map(\.title), ["invoice_feb.pdf"])
        XCTAssertTrue(similarDocs.items[0].matchedSnippet?.contains("February billing statement") == true)

        // Unindexed PDF with missing text model reports .modelsMissing cleanly.
        let unindexedResult = await imageIndexer.findSimilarAsync(to: unindexedPDF, kind: .document)
        XCTAssertEqual(unindexedResult.status, .modelsMissing)
        XCTAssertTrue(unindexedResult.items.isEmpty)
    }
}
