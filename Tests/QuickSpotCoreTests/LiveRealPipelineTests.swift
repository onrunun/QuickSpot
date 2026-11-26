import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import QuickSpotCore

/// Real on-device Metal + EmbeddingGemma 2 + Apple Vision + FSEvents + SQLite E2E verification suite.
/// Enabled explicitly via `QUICKSPOT_RUN_LIVE_E2E=1` so CI/headless environments without 865 MB GGUF weights stay green.
final class LiveRealPipelineTests: XCTestCase {
    func testLiveRealEndToEndCoordinatorOCRSemanticPDFVisualAndFSEvents() async throws {
        guard ProcessInfo.processInfo.environment["QUICKSPOT_RUN_LIVE_E2E"] == "1" else {
            throw XCTSkip("Set QUICKSPOT_RUN_LIVE_E2E=1 to run live Metal EmbeddingGemma 2 + FSEvents E2E tests.")
        }
        guard SemanticModelLocator.isHardwareSupported else {
            throw XCTSkip("Apple Silicon Metal apple7+ GPU required.")
        }
        let modelStatus = SemanticModelLocator.resolve()
        guard modelStatus.isReady else {
            throw XCTSkip("Local EmbeddingGemma 2 GGUF weights not found in \(modelStatus.directory.path)")
        }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("quickspot-live-e2e-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        let watchedDir = tempDir.appendingPathComponent("Watched", isDirectory: true)
        let excludedDir = watchedDir.appendingPathComponent("PrivateExcluded", isDirectory: true)
        let photosLibDir = watchedDir.appendingPathComponent("Photos Library.photoslibrary/resources", isDirectory: true)
        let distDir = watchedDir.appendingPathComponent("project/dist", isDirectory: true)
        for dir in [watchedDir, excludedDir, photosLibDir, distDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: tempDir) }

        // 1. Create realistic multilingual digital PDFs covering distinct domains.
        let pdfFixtures: [(name: String, text: String)] = [
            (
                "ev_protokolu.pdf",
                "Taşınmaz Kiralama Protokolü. Kiracı aylık kira bedelini her ayın beşinde ev sahibinin banka hesabına havale eder. Depozito iki aylık kira tutarıdır ve sözleşme süresi on iki aydır."
            ),
            (
                "elektrik_makbuzu.pdf",
                "Anadolu Enerji Elektrik Dağıtım A.Ş. Mesken tüketim faturası. Son ödeme tarihi 15 Kasım. Toplam ödenecek tutar 1.840 TL. Sayaç okuma dönemi Ekim ayı elektrik sarfiyatı 412 kWh."
            ),
            (
                "ucus_karti.pdf",
                "Electronic Boarding Pass. Flight TK1631 Istanbul IST to Munich MUC. Departure Gate B14, Seat 12A, Boarding Time 08:45. Checked baggage allowance 23 kg."
            ),
            (
                "k8s_guide.pdf",
                "Production Kubernetes Ingress Controller Guide. Configure automatic TLS certificates using cert-manager, Let's Encrypt ACME issuer, and nginx ingress annotations."
            ),
            (
                "tarif_ekmek.pdf",
                "Ev yapımı ekşi mayalı köy ekmeği tarifi. 500 gram organik buğday unu, 350 ml ılık su, 100 gram aktif ekşi maya ve 10 gram deniz tuzu. Hamuru 16 saat buzdolabında soğuk fermantasyona bırakın."
            )
        ]
        for fixture in pdfFixtures {
            try writeDigitalPDF(text: fixture.text, to: watchedDir.appendingPathComponent(fixture.name))
        }

        // 2. Create locked PDF, corrupt PDF, corrupt PNG, tall scrolling PNG, ignored noise, and excluded PDF.
        try writeLockedPDF(to: watchedDir.appendingPathComponent("locked_bank.pdf"))
        let corruptPDF = watchedDir.appendingPathComponent("corrupt_broken.pdf")
        let corruptPNG = watchedDir.appendingPathComponent("corrupt_broken.png")
        try Data("not a valid pdf file at all " .utf8 + Data(repeating: 0x33, count: 1500)).write(to: corruptPDF)
        try Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: UInt8(0xFF), count: 5_000)).write(to: corruptPNG)

        let tallPNG = watchedDir.appendingPathComponent("tall_scroll.png")
        try writeTallPNG(
            top: "QUARTERLY REVENUE REPORT 2026",
            mid: "OPERATING MARGIN INCREASED 18 PERCENT",
            bottom: "BOARD APPROVAL SUMMARY FINAL",
            to: tallPNG
        )
        try writeDigitalPDF(
            text: "Gizli özel belge: bu dosya hariç tutulan klasörde olduğu için kesinlikle indekslenmemelidir.",
            to: excludedDir.appendingPathComponent("secret_excluded.pdf")
        )
        try writeTallPNG(top: "NOISE", mid: "PHOTOS", bottom: "LIBRARY", to: photosLibDir.appendingPathComponent("deriv.png"))
        try writeTallPNG(top: "BUILD", mid: "DIST", bottom: "ARTIFACT", to: distDir.appendingPathComponent("bundle.png"))

        // 3. Configure isolated stores + real Metal engine + unified IndexingCoordinator.
        let suite = "QuickSpotLiveE2E-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let folderStore = IndexSettingsStore(defaults: defaults)
        folderStore.save(IndexSettings(
            folders: [watchedDir.path],
            indexOnBattery: true,
            isOCREnabled: true,
            excludedFolders: [excludedDir.path]
        ))
        let semSettingsStore = SemanticSettingsStore(defaults: defaults)
        semSettingsStore.save(SemanticSettings(isEnabled: true, customModelsDirectory: nil))

        let ocrStore = ImageOCRStore(databaseURL: tempDir.appendingPathComponent("ocr.sqlite"))
        let visStore = SemanticVectorStore(databaseURL: tempDir.appendingPathComponent("vis.sqlite"))
        let docStore = SemanticDocumentStore(databaseURL: tempDir.appendingPathComponent("docs.sqlite"))
        let engine = SemanticEmbeddingEngine(settingsStore: semSettingsStore, idleUnloadSeconds: 0)

        let ocrIndexer = ImageOCRIndexer(store: ocrStore, settingsStore: folderStore)
        let docIndexer = SemanticDocumentIndexer(documentStore: docStore, ocrStore: ocrStore, engine: engine)
        let semIndexer = SemanticImageIndexer(
            store: visStore,
            documentIndexer: docIndexer,
            engine: engine,
            folderSettingsStore: folderStore,
            semanticSettingsStore: semSettingsStore
        )
        let coordinator = IndexingCoordinator(
            ocrIndexer: ocrIndexer,
            semanticIndexer: semIndexer,
            folderSettingsStore: folderStore,
            semanticSettingsStore: semSettingsStore
        )

        // 4. Execute full coordinated 3-stage pass (OCR -> Semantic Text -> Semantic Visual).
        let tStart = Date()
        coordinator.startPass(force: true)

        let passDeadline = Date().addingTimeInterval(45.0)
        while Date() < passDeadline {
            let ocrStats = ocrStore.stats()
            let docCount = docIndexer.documentCount()
            let visCount = visStore.count(forModelID: engine.modelIdentifier)
            if ocrStats.indexedCount == 7 && docCount == 6 && visCount == 1 {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let passElapsed = Date().timeIntervalSince(tStart)
        print(String(format: "\n[LIVE E2E] 3-stage pass finished in %.2fs | OCR=%d (withText=%d) | Docs=%d | Visual=%d",
                     passElapsed, ocrStore.stats().indexedCount, ocrStore.stats().withTextCount,
                     docIndexer.documentCount(), visStore.count(forModelID: engine.modelIdentifier)))

        // Assert exact indexing counts & poison-pill failure recording & exclusions.
        XCTAssertEqual(ocrStore.stats(), OCRStoreStats(indexedCount: 7, withTextCount: 6)) // 5 PDFs + 1 locked PDF + 1 tall PNG
        XCTAssertEqual(ocrStore.existingRecords(forPaths: [corruptPDF.path])[corruptPDF.path]?.status, ImageOCRStore.statusFailed)
        XCTAssertEqual(ocrStore.existingRecords(forPaths: [corruptPNG.path])[corruptPNG.path]?.status, ImageOCRStore.statusFailed)
        XCTAssertEqual(visStore.existingEntries(forPaths: [corruptPNG.path])[corruptPNG.path]?.status, SemanticVectorStore.statusFailed)
        XCTAssertEqual(docIndexer.documentCount(), 6) // 5 digital PDFs + 1 tall PNG (locked PDF has empty text)
        XCTAssertEqual(visStore.count(forModelID: engine.modelIdentifier), 1) // tall_scroll.png
        XCTAssertTrue(ocrStore.search(query: "gizli").isEmpty, "Excluded folder leaked into OCR store!")

        // 5. Verify concurrent cold/warm query loading coalescing + cross-lingual semantic PDF/OCR accuracy.
        await engine.unloadAll()
        let concurrentQueries = ["lease agreement", "electricity bill", "uçak bileti", "kubernetes ssl", "sourdough bread"]
        let tConc = Date()
        try await withThrowingTaskGroup(of: [Float].self) { group in
            for q in concurrentQueries {
                group.addTask { try await engine.embedQuery(q) }
            }
            var count = 0
            for try await vec in group {
                XCTAssertEqual(vec.count, 768)
                count += 1
            }
            XCTAssertEqual(count, concurrentQueries.count)
        }
        print(String(format: "[LIVE E2E] 5 concurrent cold-start embedQuery calls coalesced in %.2fs", Date().timeIntervalSince(tConc)))

        // Print exact raw text<->text cosine scores across our 6 documents to inspect real calibration!
        let probeQueries: [(query: String, expectedTop: String?)] = [
            ("lease agreement", "ev_protokolu.pdf"),
            ("kira sozlesmesi", "ev_protokolu.pdf"),
            ("electricity bill", "elektrik_makbuzu.pdf"),
            ("uçak bileti", "ucus_karti.pdf"),
            ("kubernetes ssl certificate", "k8s_guide.pdf"),
            ("sourdough bread recipe", "tarif_ekmek.pdf"),
            ("quarterly revenue margin", "tall_scroll.png"),
            ("safari", nil),
            ("terminal", nil),
            ("hesap makinesi", nil),
            ("beyaz köpek", nil),
            ("kırmızı araba", nil)
        ]

        print("\n[LIVE E2E] === EMBEDDINGGEMMA 2 REAL TEXT<->TEXT CALIBRATION ===")
        for probe in probeQueries {
            let qVec = try await engine.embedQuery(probe.query)
            var qVecs = [qVec]
            if let restored = await TurkishQueryRestorer.restoredVariantAsync(for: probe.query),
               restored.caseInsensitiveCompare(probe.query) != .orderedSame {
                qVecs.append(try await engine.embedQuery(restored))
            }
            let raw = docStore.searchWithStats(queryVectors: qVecs, modelID: engine.modelIdentifier, limit: 3, minSimilarity: -1.0)
            let rawSummary = raw.hits.map { String(format: "%@(%.3f)", $0.fileName, $0.similarity) }.joined(separator: ", ")
            let filter: SearchKindFilter? = probe.expectedTop?.hasSuffix(".pdf") == true ? .pdfOnly : nil
            let filtered = await semIndexer.searchAsync(query: probe.query, filter: filter, limit: 5)
            let hitNames = filtered.map { "\($0.title)[\($0.score)]" }.joined(separator: ", ")
            print(String(format: "  %-28s | raw: %-70s | returned: [%@]",
                         (probe.query as NSString).utf8String!,
                         (rawSummary as NSString).utf8String!,
                         hitNames))

            if let expected = probe.expectedTop {
                XCTAssertEqual(filtered.first?.title, expected, "Query '\(probe.query)' top hit mismatch! raw=\(rawSummary), returned=\(hitNames)")
            } else {
                XCTAssertTrue(filtered.isEmpty, "Negative query '\(probe.query)' leaked false positives! raw=\(rawSummary), returned=\(hitNames)")
            }
        }

        // 6. Test REAL live FSEvents watcher incremental indexing (new PDF + ignored Photos Library noise).
        coordinator.startWatching()
        try await Task.sleep(nanoseconds: 500_000_000)

        let liveNewPDF = watchedDir.appendingPathComponent("saglik_tahlili.pdf")
        try writeDigitalPDF(
            text: "Hastane laboratuvar kan tahlili sonuç raporu: Hemoglobin 14.2 g/dL, Vitamin D 38 ng/mL, Demir 95 ug/dL, dahiliye doktor kontrolü.",
            to: liveNewPDF
        )
        try writeTallPNG(top: "NEW", mid: "NOISE", bottom: "IGNORED", to: photosLibDir.appendingPathComponent("new_deriv.png"))

        let fsDeadline = Date().addingTimeInterval(15.0)
        var foundViaFSEvents = false
        while Date() < fsDeadline {
            if ocrStore.rawText(forPath: liveNewPDF.path) != nil && docIndexer.documentCount() >= 7 {
                foundViaFSEvents = true
                break
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTAssertTrue(foundViaFSEvents, "Live FSEvents failed to incrementally OCR + semantically embed newly dropped PDF!")
        let bloodHits = await semIndexer.searchAsync(query: "blood test results", filter: .pdfOnly, limit: 5)
        print("[LIVE E2E] FSEvents incremental 'blood test results' -> \(bloodHits.map(\.title))")
        XCTAssertEqual(bloodHits.first?.title, "saglik_tahlili.pdf")
        XCTAssertNil(ocrStore.rawText(forPath: photosLibDir.appendingPathComponent("new_deriv.png").path))

        // 7. Verify immediate pruneFolder purges ALL 3 stores cleanly.
        coordinator.stopWatching()
        coordinator.pruneFolder(watchedDir.path)
        XCTAssertEqual(ocrStore.stats().indexedCount, 0)
        XCTAssertEqual(docIndexer.documentCount(), 0)
        XCTAssertEqual(visStore.count(forModelID: engine.modelIdentifier), 0)

        await engine.unloadAll()
    }

    func testLiveRealExistingDatabaseMigrationAndPerformanceBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["QUICKSPOT_RUN_LIVE_E2E"] == "1" else {
            throw XCTSkip("Set QUICKSPOT_RUN_LIVE_E2E=1 to run live DB copy migration & latency benchmarks.")
        }

        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("QuickSpot", isDirectory: true)
        let realOCR = appSupport.appendingPathComponent("image-ocr.sqlite")
        let realVec = appSupport.appendingPathComponent("image-embeddings.sqlite")
        guard fm.fileExists(atPath: realOCR.path), fm.fileExists(atPath: realVec.path) else {
            throw XCTSkip("No existing QuickSpot SQLite databases found to benchmark.")
        }

        let tmpDir = fm.temporaryDirectory
            .appendingPathComponent("quickspot-live-bench-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        func copySQLiteBundle(_ src: URL, to dst: URL) throws {
            try fm.copyItem(at: src, to: dst)
            for suffix in ["-wal", "-shm"] {
                let s = URL(fileURLWithPath: src.path + suffix)
                if fm.fileExists(atPath: s.path) {
                    try fm.copyItem(at: s, to: URL(fileURLWithPath: dst.path + suffix))
                }
            }
        }

        let ocrCopy = tmpDir.appendingPathComponent("ocr-copy.sqlite")
        let vecCopy = tmpDir.appendingPathComponent("vec-copy.sqlite")
        try copySQLiteBundle(realOCR, to: ocrCopy)
        try copySQLiteBundle(realVec, to: vecCopy)

        // 1. Real v2 -> v3 OCR DB migration + stats() + WAL search latency
        let tMig = Date()
        let ocrStore = ImageOCRStore(databaseURL: ocrCopy)
        let migMs = Date().timeIntervalSince(tMig) * 1000.0

        let tStats = Date()
        var stats = OCRStoreStats(indexedCount: 0, withTextCount: 0)
        for _ in 0..<100 {
            stats = ocrStore.stats()
        }
        let statsAvgMs = (Date().timeIntervalSince(tStats) * 1000.0) / 100.0

        let tSearch = Date()
        let imgHits = ocrStore.search(query: "fatura", kind: .image, limit: 12)
        let pdfHits = ocrStore.search(query: "fatura", kind: .pdf, limit: 12)
        let searchMs = Date().timeIntervalSince(tSearch) * 1000.0

        print(String(
            format: "\n[LIVE BENCH] OCR DB copy: migrate=%.1fms | rows=%d (withText=%d) | stats() avg=%.3fms (100x) | img+pdf search=%.2fms (img=%d, pdf=%d)",
            migMs, stats.indexedCount, stats.withTextCount, statsAvgMs, searchMs, imgHits.count, pdfHits.count
        ))
        XCTAssertLessThan(statsAvgMs, 5.0, "stats() should be sub-millisecond with has_text column!")

        // 2. Real SemanticVectorStore migration + matrix load + vDSP_mmul latency
        let tVecOpen = Date()
        let vecStore = SemanticVectorStore(databaseURL: vecCopy)
        let vecOpenMs = Date().timeIntervalSince(tVecOpen) * 1000.0
        let vecCount = vecStore.count(forModelID: SemanticModelLocator.modelIdentifier)

        var dummyQuery = [Float](repeating: 0, count: SemanticModelLocator.embeddingDimension)
        dummyQuery[0] = 1.0
        let tCold = Date()
        _ = vecStore.searchWithStats(queryVector: dummyQuery, modelID: SemanticModelLocator.modelIdentifier, limit: 10)
        let coldMs = Date().timeIntervalSince(tCold) * 1000.0

        let tWarm = Date()
        for _ in 0..<50 {
            _ = vecStore.searchWithStats(queryVector: dummyQuery, modelID: SemanticModelLocator.modelIdentifier, limit: 10)
        }
        let warmAvgMs = (Date().timeIntervalSince(tWarm) * 1000.0) / 50.0

        print(String(
            format: "[LIVE BENCH] Vector DB copy: open+migrate=%.1fms | vectors=%d | cold matrix+hubness=%.2fms | warm vDSP avg=%.3fms (50x)",
            vecOpenMs, vecCount, coldMs, warmAvgMs
        ))
        XCTAssertLessThan(warmAvgMs, 5.0, "Warm vDSP vector search should be sub-millisecond!")
    }

    // MARK: - Fixture Generators

    private func writeDigitalPDF(text: String, to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 400)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            XCTFail("Failed to create PDF context")
            return
        }
        ctx.beginPDFPage(nil)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        let rect = NSRect(x: 36, y: 40, width: 540, height: 320)
        NSString(string: text).draw(in: rect, withAttributes: [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.black
        ])
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
    }

    private func writeLockedPDF(to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 180)
        let auxInfo: [CFString: Any] = [
            kCGPDFContextUserPassword: "user-lock",
            kCGPDFContextOwnerPassword: "owner-lock"
        ]
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, auxInfo as CFDictionary) else {
            XCTFail("Failed to create locked PDF")
            return
        }
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    private func writeTallPNG(top: String, mid: String, bottom: String, to url: URL) throws {
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
            .font: NSFont.boldSystemFont(ofSize: 40),
            .foregroundColor: NSColor.black
        ]
        NSString(string: top).draw(at: NSPoint(x: 36, y: 3420), withAttributes: attrs)
        NSString(string: mid).draw(at: NSPoint(x: 36, y: 1800), withAttributes: attrs)
        NSString(string: bottom).draw(at: NSPoint(x: 36, y: 140), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
