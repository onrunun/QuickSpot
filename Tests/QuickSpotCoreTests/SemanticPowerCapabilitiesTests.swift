import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import QuickSpotCore

private final class PowerCapabilitiesMockProvider: SemanticEmbeddingProvider, @unchecked Sendable {
    let modelIdentifier: String = "mock-power:4d"
    let dimension: Int = 4
    let status: SemanticModelStatus
    let queryVectors: [String: [Float]]
    let clipboardVector: [Float]

    init(
        status: SemanticModelStatus,
        queryVectors: [String: [Float]] = [:],
        clipboardVector: [Float] = [1, 0, 0, 0]
    ) {
        self.status = status
        self.queryVectors = queryVectors
        self.clipboardVector = clipboardVector
    }

    func modelStatus() async -> SemanticModelStatus { status }
    func isTextModelReady() async -> Bool { status.isReady }

    func embedQuery(_ text: String) async throws -> [Float] {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return queryVectors[key] ?? [0, 0, 0, 1]
    }

    func embedImages(_ urls: [URL]) async throws -> [(url: URL, vector: [Float])] {
        urls.map { ($0, clipboardVector) }
    }

    func embedImage(_ cgImage: CGImage) async throws -> [Float] {
        clipboardVector
    }

    func releaseImageEncoder() async {}
    func unloadAll() async {}
}

final class SemanticPowerCapabilitiesTests: XCTestCase {
    func testNegativeQueryExpressionParsingAndPreservation() {
        let simple = SemanticQueryExpression.parse("araba -gece")
        XCTAssertEqual(simple.positiveQuery, "araba")
        XCTAssertEqual(simple.negativeTerms, ["gece"])

        let quoted = SemanticQueryExpression.parse("fatura -\"ekran goruntusu\" -taslak")
        XCTAssertEqual(quoted.positiveQuery, "fatura")
        XCTAssertEqual(quoted.negativeTerms, ["ekran goruntusu", "taslak"])

        // Hyphenated words and arithmetic must NOT be treated as negative concepts.
        let hyphenated = SemanticQueryExpression.parse("wi-fi e-mail settings")
        XCTAssertEqual(hyphenated.positiveQuery, "wi-fi e-mail settings")
        XCTAssertTrue(hyphenated.negativeTerms.isEmpty)

        let math = SemanticQueryExpression.parse("10 - 5")
        XCTAssertEqual(math.positiveQuery, "10 - 5")
        XCTAssertTrue(math.negativeTerms.isEmpty)

        let onlyNeg = SemanticQueryExpression.parse("-gece")
        XCTAssertEqual(onlyNeg.positiveQuery, "-gece")
        XCTAssertTrue(onlyNeg.negativeTerms.isEmpty)
    }

    func testNegativeConceptSearchCrossModalAndClipboardImageReverseSearch() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("quickspot-power-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let dayCar = tempDir.appendingPathComponent("day_car.jpg")
        let nightCar = tempDir.appendingPathComponent("night_car.jpg")
        let archDiagram = tempDir.appendingPathComponent("diagram.png")
        let archPDF = tempDir.appendingPathComponent("architecture.pdf")
        for url in [dayCar, nightCar, archDiagram, archPDF] {
            try Data(repeating: 0xAA, count: 2048).write(to: url)
        }

        let suite = "QuickSpotPower-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let semSettings = SemanticSettingsStore(defaults: defaults)
        semSettings.save(SemanticSettings(isEnabled: true, customModelsDirectory: nil))

        let readyStatus = SemanticModelStatus.ready(
            textURL: tempDir.appendingPathComponent("t.gguf"),
            mmprojURL: tempDir.appendingPathComponent("m.gguf"),
            directory: tempDir
        )
        let provider = PowerCapabilitiesMockProvider(
            status: readyStatus,
            queryVectors: [
                "car": [1, 0, 0, 0],
                "night": [0, 1, 0, 0]
            ],
            clipboardVector: [0, 0, 1, 0]
        )

        let imgStore = SemanticVectorStore(databaseURL: tempDir.appendingPathComponent("img.sqlite"))
        let docStore = SemanticDocumentStore(databaseURL: tempDir.appendingPathComponent("doc.sqlite"))
        let ocrStore = ImageOCRStore(databaseURL: tempDir.appendingPathComponent("ocr.sqlite"))
        let now = Date().timeIntervalSince1970

        imgStore.upsert(path: dayCar.path, name: dayCar.lastPathComponent, mtime: now, size: 2048, modelID: provider.modelIdentifier, vector: [0.95, 0.0, 0.0, 0.312])
        imgStore.upsert(path: nightCar.path, name: nightCar.lastPathComponent, mtime: now, size: 2048, modelID: provider.modelIdentifier, vector: [0.70, 0.714, 0.0, 0.0])
        imgStore.upsert(path: archDiagram.path, name: archDiagram.lastPathComponent, mtime: now, size: 2048, modelID: provider.modelIdentifier, vector: [0.0, 0.0, 1.0, 0.0])

        docStore.upsertDocumentChunks(
            path: archPDF.path,
            name: archPDF.lastPathComponent,
            kind: .pdf,
            mtime: now,
            size: 2048,
            modelID: provider.modelIdentifier,
            chunks: [
                (SemanticTextChunk(index: 0, embedInput: "arch", excerpt: "System architecture overview"), [0.0, 0.0, 0.96, 0.28])
            ]
        )

        let docIndexer = SemanticDocumentIndexer(documentStore: docStore, ocrStore: ocrStore, engine: provider)
        let indexer = SemanticImageIndexer(
            store: imgStore,
            documentIndexer: docIndexer,
            engine: provider,
            folderSettingsStore: IndexSettingsStore(defaults: defaults),
            semanticSettingsStore: semSettings,
            generalMinSimilarity: 0.4,
            imageFilterMinSimilarity: 0.3
        )

        // 1. Negative concept "car -night" prioritizes day_car and suppresses night_car.
        let negHits = await indexer.searchAsync(query: "car -night")
        XCTAssertEqual(negHits.first?.title, "day_car.jpg")
        XCTAssertFalse(negHits.contains(where: { $0.title == "night_car.jpg" }))

        // 2. Cross-modal: Image -> Document finds architecture.pdf; Document -> Image finds diagram.png!
        XCTAssertTrue(indexer.hasBothModalitiesIndexed())
        let imgToDoc = await indexer.findSimilarAsync(to: archDiagram, kind: .image, scope: .documents)
        XCTAssertEqual(imgToDoc.status, .ready)
        XCTAssertEqual(imgToDoc.items.map(\.title), ["architecture.pdf"])

        let docToImg = await indexer.findSimilarAsync(to: archPDF, kind: .document, scope: .images)
        XCTAssertEqual(docToImg.status, .ready)
        XCTAssertEqual(docToImg.items.map(\.title), ["diagram.png"])

        // 3. In-memory CGImage clipboard reverse search across `.all` finds both diagram.png and architecture.pdf!
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let dummyCGImage = try XCTUnwrap(ctx.makeImage())
        let embedded = await indexer.embedClipboardImageAsync(dummyCGImage)
        XCTAssertEqual(embedded.status, .ready)
        let clipVec = try XCTUnwrap(embedded.vector)

        let clipAll = await indexer.findSimilarByVectorAsync(clipVec, scope: .all)
        XCTAssertEqual(clipAll.status, .ready)
        XCTAssertEqual(Set(clipAll.items.map(\.title)), ["diagram.png", "architecture.pdf"])
    }

    func testNearDuplicateFinderClusteringQualityRankingAndCleanup() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("quickspot-dups-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let highResOriginal = tempDir.appendingPathComponent("photo_original.png")
        let compressedCopy = tempDir.appendingPathComponent("photo_whatsapp.jpg")
        let unrelatedPhoto = tempDir.appendingPathComponent("sunset.jpg")

        try Data(repeating: 0x11, count: 50_000).write(to: highResOriginal)
        try Data(repeating: 0x22, count: 8_000).write(to: compressedCopy)
        try Data(repeating: 0x33, count: 12_000).write(to: unrelatedPhoto)

        let suite = "QuickSpotDups-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let readyStatus = SemanticModelStatus.ready(
            textURL: tempDir.appendingPathComponent("t.gguf"),
            mmprojURL: tempDir.appendingPathComponent("m.gguf"),
            directory: tempDir
        )
        let provider = PowerCapabilitiesMockProvider(status: readyStatus)
        let store = SemanticVectorStore(databaseURL: tempDir.appendingPathComponent("dups.sqlite"))
        let now = Date().timeIntervalSince1970

        // Cosine between [1, 0, 0, 0] and [0.98, 0.199, 0, 0] is 0.98 >= 0.94
        store.upsert(path: highResOriginal.path, name: highResOriginal.lastPathComponent, mtime: now - 100, size: 50_000, modelID: provider.modelIdentifier, vector: [1.0, 0.0, 0.0, 0.0])
        store.upsert(path: compressedCopy.path, name: compressedCopy.lastPathComponent, mtime: now, size: 8_000, modelID: provider.modelIdentifier, vector: [0.98, 0.199, 0.0, 0.0])
        store.upsert(path: unrelatedPhoto.path, name: unrelatedPhoto.lastPathComponent, mtime: now, size: 12_000, modelID: provider.modelIdentifier, vector: [0.0, 0.0, 1.0, 0.0])

        let indexer = SemanticImageIndexer(
            store: store,
            engine: provider,
            folderSettingsStore: IndexSettingsStore(defaults: defaults),
            semanticSettingsStore: SemanticSettingsStore(defaults: defaults)
        )

        let groups = await indexer.findNearDuplicateImagesAsync(threshold: 0.94)
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.items.count, 2)
        XCTAssertEqual(group.items[0].fileName, "photo_original.png")
        XCTAssertTrue(group.items[0].isRecommendedKeep)
        XCTAssertEqual(group.items[1].fileName, "photo_whatsapp.jpg")
        XCTAssertFalse(group.items[1].isRecommendedKeep)
        XCTAssertEqual(group.reclaimableBytes, 8_000)

        // Removing the duplicate path clears the group immediately.
        indexer.removeIndexedPaths([compressedCopy.path])
        let afterCleanup = await indexer.findNearDuplicateImagesAsync(threshold: 0.94)
        XCTAssertTrue(afterCleanup.isEmpty)
    }

    func testVisionQRDetectionIBANValidationSmartEntitiesAndCommands() throws {
        // 1. ISO 13616 Mod-97 IBAN validation
        XCTAssertTrue(ImageIntelligenceService.isValidIBAN("TR33 0006 1005 1978 6457 8413 26"))
        XCTAssertTrue(ImageIntelligenceService.isValidIBAN("DE89 3704 0044 0532 0130 00"))
        XCTAssertFalse(ImageIntelligenceService.isValidIBAN("TR33 0006 1005 1978 6457 8413 27")) // invalid checksum
        XCTAssertFalse(ImageIntelligenceService.isValidIBAN("XX00 1234 5678 9012 3456"))

        // 2. Smart entity extraction from receipt OCR text (including same-line trailing text after IBAN)
        let receiptText = """
        Fatura Ödeme Bilgileri
        IBAN: TR33 0006 1005 1978 6457 8413 26 Ornek Alıcı
        Web: https://quickspot.example.com/invoice/42
        Destek: billing@example.com
        Tel: +90 212 555 01 99
        """
        let entities = ImageIntelligenceService.extractSmartEntities(from: receiptText)
        let kinds = Set(entities.map(\.kind))
        XCTAssertTrue(kinds.contains(.iban))
        XCTAssertTrue(kinds.contains(.url))
        XCTAssertTrue(kinds.contains(.email))
        XCTAssertTrue(kinds.contains(.phone))
        XCTAssertEqual(entities.first(where: { $0.kind == .iban })?.copyValue, "TR330006100519786457841326")

        // 3. Real Apple Vision QR code detection on a synthesized CIQRCodeGenerator image
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data("https://example.com/quickspot".utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let scaled = try XCTUnwrap(filter.outputImage)
            .transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        // Add white quiet zone around the QR code so VNDetectBarcodesRequest reliably reads it
        let paddedExtent = scaled.extent.insetBy(dx: -40, dy: -40)
        let whiteBG = CIImage(color: .white).cropped(to: paddedExtent)
        let composited = scaled.composited(over: whiteBG)
        let ciContext = CIContext()
        let qrCGImage = try XCTUnwrap(ciContext.createCGImage(composited, from: paddedExtent))

        let qrEntities = ImageIntelligenceService.detectBarcodes(in: qrCGImage)
        XCTAssertEqual(qrEntities.first?.kind, .qrURL)
        XCTAssertEqual(qrEntities.first?.copyValue, "https://example.com/quickspot")
        XCTAssertEqual(qrEntities.first?.openURL?.absoluteString, "https://example.com/quickspot")

        // 4. Multilingual system command matching for Duplicate Finder & Clipboard Reverse Image
        XCTAssertEqual(SystemCommandAction.match(query: "ikiz").first?.id, "sys:duplicates")
        XCTAssertEqual(SystemCommandAction.match(query: "duplicate").first?.id, "sys:duplicates")
        XCTAssertEqual(SystemCommandAction.match(query: "reverse image").first?.id, "sys:clipboard_similar")
    }
}
