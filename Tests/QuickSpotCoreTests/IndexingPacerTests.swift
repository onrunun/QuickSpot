import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import QuickSpotCore

final class IndexingPacerTests: XCTestCase {
    func testIndexSettingsDefaultsToQuietAndPersistsModeChanges() throws {
        let suite = "QuickSpotPacerSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = IndexSettingsStore(defaults: defaults)
        XCTAssertEqual(store.load().indexingMode, .quiet)

        var updated = store.load()
        updated.indexingMode = .fast
        store.save(updated)
        XCTAssertEqual(IndexSettingsStore(defaults: defaults).load().indexingMode, .fast)

        updated.indexingMode = .quiet
        store.save(updated)
        XCTAssertEqual(IndexSettingsStore(defaults: defaults).load().indexingMode, .quiet)
    }

    func testQuietModeTaskPriorityCrawlThrottleAndCalibratedBatchSizing() {
        let state = MockEnvState(mode: .quiet, thermal: .nominal, idleSeconds: 0, onAC: true, searchActive: false)
        let pacer = makePacer(state: state)

        XCTAssertEqual(pacer.taskPriority(force: false), .background)
        XCTAssertEqual(pacer.taskPriority(force: true), .background)
        XCTAssertGreaterThan(pacer.crawlThrottleDelay, 0)
        XCTAssertEqual(pacer.batchSize(for: .ocr), 1)
        XCTAssertEqual(pacer.batchSize(for: .semanticDocument), 6)
        XCTAssertEqual(pacer.batchSize(for: .semanticVisual), 1)

        // Idle boost on AC steps up smoothly (2-image visual, 12-chunk text sweet spot).
        state.idleSeconds = IndexingPacer.idleBoostThresholdSeconds + 30
        XCTAssertEqual(pacer.batchSize(for: .semanticDocument), 12)
        XCTAssertEqual(pacer.batchSize(for: .semanticVisual), 2)

        // Idle boost does NOT engage on battery power.
        state.onAC = false
        XCTAssertEqual(pacer.batchSize(for: .semanticDocument), 6)
        XCTAssertEqual(pacer.batchSize(for: .semanticVisual), 1)

        // Thermal .fair shrinks batches immediately to keep fans calm.
        state.onAC = true
        state.thermal = .fair
        XCTAssertEqual(pacer.batchSize(for: .semanticDocument), 4)
        XCTAssertEqual(pacer.batchSize(for: .semanticVisual), 1)
        XCTAssertGreaterThan(pacer.crawlThrottleDelay, 0.005)

        // Fast mode uses calibrated 4-image visual / 16-chunk text batches on nominal, and scales down under .fair.
        state.mode = .fast
        state.thermal = .nominal
        XCTAssertEqual(pacer.taskPriority(force: false), .utility)
        XCTAssertEqual(pacer.crawlThrottleDelay, 0)
        XCTAssertEqual(pacer.batchSize(for: .semanticDocument), 16)
        XCTAssertEqual(pacer.batchSize(for: .semanticVisual), 4)

        state.thermal = .fair
        XCTAssertEqual(pacer.batchSize(for: .semanticDocument), 8)
        XCTAssertEqual(pacer.batchSize(for: .semanticVisual), 2)
    }

    func testCalibratedDutyCycleCooldownScalingAndDigitalPDFFastPath() {
        let state = MockEnvState(mode: .quiet, thermal: .nominal, idleSeconds: 0, onAC: true, searchActive: false)
        let pacer = makePacer(state: state)

        // Fast-path embedded digital PDF (~5ms) should not incur heavy ANE cooldown floors.
        let digitalPDFCooldown = pacer.cooldownDuration(for: .ocr, workDuration: 0.005, force: false)
        XCTAssertLessThanOrEqual(digitalPDFCooldown, 0.025)
        XCTAssertGreaterThanOrEqual(digitalPDFCooldown, 0.01)

        // Realistic M1 Pro 1.0s Vision OCR (~2W ANE) rests ~0.55s (~64% ANE duty cycle).
        let imageOCRCooldown = pacer.cooldownDuration(for: .ocr, workDuration: 1.0, force: false)
        XCTAssertEqual(imageOCRCooldown, 0.55, accuracy: 0.001)

        // Realistic M1 Pro 520ms single-image Metal visual rests ~858ms (~38% GPU duty cycle).
        let activeVisualCooldown = pacer.cooldownDuration(for: .semanticVisual, workDuration: 0.52, force: false)
        XCTAssertEqual(activeVisualCooldown, 0.858, accuracy: 0.001)

        // Idle boost reduces cooldown substantially while keeping a thermal floor.
        state.idleSeconds = 300
        let idleVisualCooldown = pacer.cooldownDuration(for: .semanticVisual, workDuration: 0.52, force: false)
        XCTAssertLessThan(idleVisualCooldown, activeVisualCooldown)
        XCTAssertGreaterThan(idleVisualCooldown, 0.05)

        // Thermal .fair increases cooldown well above active Quiet mode.
        state.thermal = .fair
        let fairVisualCooldown = pacer.cooldownDuration(for: .semanticVisual, workDuration: 0.52, force: false)
        XCTAssertGreaterThan(fairVisualCooldown, activeVisualCooldown)

        // Fast mode has zero sleep on nominal, but backs off on .fair and .critical.
        state.mode = .fast
        state.thermal = .nominal
        XCTAssertEqual(pacer.cooldownDuration(for: .semanticVisual, workDuration: 0.52, force: false), 0)

        state.thermal = .fair
        XCTAssertGreaterThan(pacer.cooldownDuration(for: .semanticVisual, workDuration: 0.52, force: false), 0.30)

        state.thermal = .critical
        XCTAssertGreaterThanOrEqual(pacer.cooldownDuration(for: .semanticVisual, workDuration: 0.52, force: true), 0.60)
    }

    func testWaitBeforeWorkYieldsWhileInteractiveSearchIsOpen() async {
        let state = MockEnvState(mode: .quiet, thermal: .nominal, idleSeconds: 0, onAC: true, searchActive: true)
        let recorder = SleepRecorder()
        let pacer = IndexingPacer(
            modeProvider: { state.mode },
            thermalStateProvider: { state.thermal },
            idleSecondsProvider: { state.idleSeconds },
            isOnACPowerProvider: { state.onAC },
            isInteractiveSearchActiveProvider: { state.searchActive },
            sleepHandler: { nanos in
                let count = recorder.record(nanos)
                if count >= 2 {
                    state.searchActive = false
                }
            }
        )

        await pacer.waitBeforeWork()
        XCTAssertEqual(recorder.calls.count, 2)
    }

    func testMultiPageScannedPDFCooperativePacingAndMidFileCancellation() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("quickspot-pacer-pdf-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let pdfURL = tempDir.appendingPathComponent("scanned_3p.pdf")
        try writeThreePageScannedPDF(to: pdfURL)

        // 1. Full cooperative extraction invokes inter-page cooldown twice for 3 scanned pages.
        let pageCooldowns = SleepRecorder()
        let pacedResult = await VisionTextExtractor.extractTextResultAsync(
            from: pdfURL,
            shouldContinue: { true },
            afterOCRUnit: { elapsed in
                _ = pageCooldowns.record(UInt64(max(1, elapsed * 1_000_000)))
            }
        )
        let extractedText = try pacedResult.get()
        XCTAssertTrue(extractedText.localizedCaseInsensitiveContains("CALIBRATION"), "Expected OCR text from scanned PDF")
        XCTAssertEqual(pageCooldowns.calls.count, 2, "Should pace between pages (2 gaps for 3 pages), not after final page")

        // 2. Mid-PDF cancellation stops cleanly with CancellationError and leaves zero poison-pill failure records.
        let checkCounter = SleepRecorder()
        let cancelledResult = await VisionTextExtractor.extractTextResultAsync(
            from: pdfURL,
            shouldContinue: {
                checkCounter.record(1) <= 1
            },
            afterOCRUnit: { _ in }
        )
        if case .failure(let err) = cancelledResult {
            XCTAssertTrue(err is CancellationError, "Expected CancellationError when shouldContinue returns false")
        } else {
            XCTFail("Expected cooperative cancellation on page 2")
        }
    }

    func testSemanticVisualAndDocumentIndexersUseCalibratedQuietPulsesAndCooldowns() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("quickspot-pacer-int-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        var pngPaths: [String] = []
        for idx in 1...5 {
            let url = tempDir.appendingPathComponent("photo_\(idx).png")
            try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: url)
            pngPaths.append(url.path)
        }

        let suite = "QuickSpotPacerInt-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let folderStore = IndexSettingsStore(defaults: defaults)
        folderStore.save(IndexSettings(folders: [tempDir.path], indexOnBattery: true, isOCREnabled: true, indexingMode: .quiet))
        let semSettings = SemanticSettingsStore(defaults: defaults)
        semSettings.save(SemanticSettings(isEnabled: true, customModelsDirectory: nil))

        let ocrStore = ImageOCRStore(databaseURL: tempDir.appendingPathComponent("ocr.sqlite"))
        for idx in 1...3 {
            let docPath = tempDir.appendingPathComponent("doc_\(idx).pdf").path
            let text = String(repeating: "Quiet background indexing paragraph \(idx). ", count: 25)
            ocrStore.upsert(
                path: docPath,
                name: "doc_\(idx).pdf",
                mtime: Double(idx),
                size: 1024,
                rawText: text,
                foldedText: VisionTextExtractor.normalizeForSearch(text),
                status: ImageOCRStore.statusIndexed
            )
        }

        let recorder = SleepRecorder()
        let pacer = IndexingPacer(
            modeProvider: { folderStore.load().indexingMode },
            thermalStateProvider: { .nominal },
            idleSecondsProvider: { 0 },
            isOnACPowerProvider: { true },
            isInteractiveSearchActiveProvider: { false },
            sleepHandler: { nanos in
                _ = recorder.record(nanos)
            }
        )

        let readyStatus = SemanticModelStatus.ready(
            textURL: tempDir.appendingPathComponent("text.gguf"),
            mmprojURL: tempDir.appendingPathComponent("mmproj.gguf"),
            directory: tempDir
        )
        let provider = BatchRecordingProvider(status: readyStatus)
        let docStore = SemanticDocumentStore(databaseURL: tempDir.appendingPathComponent("docs.sqlite"))
        let visStore = SemanticVectorStore(databaseURL: tempDir.appendingPathComponent("vis.sqlite"))
        let docIndexer = SemanticDocumentIndexer(documentStore: docStore, ocrStore: ocrStore, engine: provider, pacer: pacer)
        let semIndexer = SemanticImageIndexer(
            store: visStore,
            documentIndexer: docIndexer,
            engine: provider,
            folderSettingsStore: folderStore,
            semanticSettingsStore: semSettings,
            pacer: pacer
        )

        await docIndexer.reconcileAll(force: false, blockerProvider: { nil }, isEnabled: { true })
        XCTAssertEqual(docIndexer.documentCount(), 3)
        XCTAssertGreaterThanOrEqual(recorder.calls.count, 2, "Quiet document indexing should cool down between documents")

        let sleepsBeforeVisual = recorder.calls.count
        let discovered = pngPaths.enumerated().map { idx, path in
            DiscoveredImage(url: URL(fileURLWithPath: path), mtime: Double(idx + 1), size: 8)
        }
        await semIndexer.runCoordinatedPass(discovered: discovered, force: false)

        XCTAssertEqual(visStore.count(forModelID: provider.modelIdentifier), 5)
        XCTAssertEqual(
            provider.recordedImageBatchSizes,
            [1, 1, 1, 1, 1],
            "Quiet mode should process 1 image per Metal pulse to minimize peak heat and interactive query stalls"
        )
        XCTAssertEqual(recorder.calls.count - sleepsBeforeVisual, 4, "Cooldown should run between images, not after the final image")
    }

    private func makePacer(state: MockEnvState) -> IndexingPacer {
        IndexingPacer(
            modeProvider: { state.mode },
            thermalStateProvider: { state.thermal },
            idleSecondsProvider: { state.idleSeconds },
            isOnACPowerProvider: { state.onAC },
            isInteractiveSearchActiveProvider: { state.searchActive },
            sleepHandler: { _ in }
        )
    }

    private func writeThreePageScannedPDF(to url: URL) throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 480, pixelsHigh: 180,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 480, height: 180).fill()
        NSString(string: "CALIBRATION PAGE").draw(
            at: NSPoint(x: 24, y: 64),
            withAttributes: [.font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.black]
        )
        NSGraphicsContext.restoreGraphicsState()
        let cgImage = try XCTUnwrap(rep.cgImage)

        var box = CGRect(x: 0, y: 0, width: 480, height: 180)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 1...3 {
            ctx.beginPDFPage(nil)
            ctx.draw(cgImage, in: box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}

private final class MockEnvState: @unchecked Sendable {
    private let lock = NSLock()
    private var _mode: IndexingMode
    private var _thermal: ProcessInfo.ThermalState
    private var _idleSeconds: TimeInterval
    private var _onAC: Bool
    private var _searchActive: Bool

    init(
        mode: IndexingMode,
        thermal: ProcessInfo.ThermalState,
        idleSeconds: TimeInterval,
        onAC: Bool,
        searchActive: Bool
    ) {
        self._mode = mode
        self._thermal = thermal
        self._idleSeconds = idleSeconds
        self._onAC = onAC
        self._searchActive = searchActive
    }

    var mode: IndexingMode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }
    var thermal: ProcessInfo.ThermalState {
        get { lock.withLock { _thermal } }
        set { lock.withLock { _thermal = newValue } }
    }
    var idleSeconds: TimeInterval {
        get { lock.withLock { _idleSeconds } }
        set { lock.withLock { _idleSeconds = newValue } }
    }
    var onAC: Bool {
        get { lock.withLock { _onAC } }
        set { lock.withLock { _onAC = newValue } }
    }
    var searchActive: Bool {
        get { lock.withLock { _searchActive } }
        set { lock.withLock { _searchActive = newValue } }
    }
}

private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [UInt64] = []

    var calls: [UInt64] {
        lock.withLock { recorded }
    }

    @discardableResult
    func record(_ nanos: UInt64) -> Int {
        lock.withLock {
            recorded.append(nanos)
            return recorded.count
        }
    }
}

private final class BatchRecordingProvider: SemanticEmbeddingProvider, @unchecked Sendable {
    let modelIdentifier = "mock-pacer-model"
    let dimension = 4
    private let status: SemanticModelStatus
    private let lock = NSLock()
    private var imageBatches: [Int] = []

    init(status: SemanticModelStatus) {
        self.status = status
    }

    var recordedImageBatchSizes: [Int] {
        lock.withLock { imageBatches }
    }

    func modelStatus() async -> SemanticModelStatus { status }
    func isTextModelReady() async -> Bool { status.isReady }
    func embedQuery(_ text: String) async throws -> [Float] { [1, 0, 0, 0] }

    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [1, 0, 0, 0] }
    }

    func embedImages(_ urls: [URL]) async throws -> [(url: URL, vector: [Float])] {
        lock.withLock { imageBatches.append(urls.count) }
        return urls.map { ($0, [1, 0, 0, 0]) }
    }

    func releaseImageEncoder() async {}
    func unloadAll() async {}
}
