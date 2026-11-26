import Foundation
import XCTest
@testable import QuickSpotCore

extension RankingAndFileSearchTests {
    // MARK: - SystemCommandAction & QuickActionRouter

    func testSystemCommandCalibrationDestructiveGuardsAndGoogleFallback() throws {
        // Prefix command ("tem" -> "tema") must NOT beat a real app prefix match (>= 840)
        let temCmd = try XCTUnwrap(SystemCommandAction.match(query: "tem").first)
        XCTAssertEqual(temCmd.id, "sys:darkmode")
        XCTAssertFalse(temCmd.requiresConfirmation)
        XCTAssertLessThan(temCmd.score, 840)
        let terminalPrefix = try XCTUnwrap(FuzzyMatcher.score(query: "ter", candidate: "Terminal"))
        XCTAssertGreaterThanOrEqual(terminalPrefix, 840)
        XCTAssertLessThan(temCmd.score, terminalPrefix)

        // Exact "index" settings command (960) does not blindly crush a recent exact file `index.ts`
        let indexCmd = try XCTUnwrap(SystemCommandAction.match(query: "index").first)
        XCTAssertEqual(indexCmd.action, .openSettings)
        XCTAssertEqual(indexCmd.score, 960)

        let recentFileScore = SpotlightQueryBuilder.scoreFilenameMatch(
            query: "index",
            fileName: "index.ts",
            standardizedPath: "/Users/tester/Projects/app/index.ts",
            referenceDate: Date(),
            frecencyBoost: 0,
            homeDirectory: "/Users/tester"
        )
        XCTAssertGreaterThan(recentFileScore, indexCmd.score)

        // Destructive commands require confirmation and are guarded against 2-char queries
        for (query, expectedID) in [
            ("restart", "sys:restart"),
            ("shutdown", "sys:shutdown"),
            ("empty trash", "sys:trash")
        ] {
            let item = try XCTUnwrap(SystemCommandAction.match(query: query).first, "Missing \(expectedID)")
            XCTAssertEqual(item.id, expectedID)
            XCTAssertTrue(item.requiresConfirmation)
            XCTAssertEqual(item.score, 860)
        }

        let destructiveIDs: Set<String> = ["sys:restart", "sys:shutdown", "sys:trash"]
        for shortQuery in ["ka", "co", "re", "sh"] {
            let matchedIDs = Set(SystemCommandAction.match(query: shortQuery).map(\.id))
            XCTAssertTrue(
                matchedIDs.isDisjoint(with: destructiveIDs),
                "Short query '\(shortQuery)' should not trigger destructive commands: \(matchedIDs)"
            )
        }

        XCTAssertNotNil(SystemCommandExecutor.executeWithError("unknown-quickspot-cmd"))

        // QuickActionRouter suppresses Google fallback when a strong local hit (>= 720) exists
        let strongHit = SearchItem(
            id: "file:/tmp/rapor.pdf",
            title: "rapor.pdf",
            subtitle: "/tmp",
            category: .file,
            score: 720,
            action: .openFile(URL(fileURLWithPath: "/tmp/rapor.pdf")),
            previewURL: URL(fileURLWithPath: "/tmp/rapor.pdf")
        )
        let actionsWithStrong = QuickActionRouter.generate(for: "rapor taslagi", localHits: [strongHit])
        XCTAssertFalse(actionsWithStrong.contains { $0.id.hasPrefix("web:") })

        let weakHit = strongHit.withScore(719)
        let actionsWithWeak = QuickActionRouter.generate(for: "rapor taslagi", localHits: [weakHit])
        XCTAssertTrue(actionsWithWeak.contains { $0.id == "web:rapor taslagi" })
    }

    // MARK: - ResultRanker

    func testResultRankerDualSignalFusionAndDiversitySlots() throws {
        // 1. Dual-signal fusion: same canonical path in Spotlight + OCR merges into 1 boosted item with snippet
        let unstandardizedURL = URL(fileURLWithPath: "/tmp/sub/../fatura_2026.pdf")
        let canonicalURL = URL(fileURLWithPath: "/tmp/fatura_2026.pdf")

        let spotlightHit = SearchItem(
            id: "file:\(unstandardizedURL.path)",
            title: "fatura_2026.pdf",
            subtitle: "/tmp",
            category: .file,
            iconPath: unstandardizedURL.path,
            score: 820,
            action: .openFile(unstandardizedURL),
            previewURL: unstandardizedURL,
            matchedSnippet: nil,
            matchSource: .name
        )
        let ocrHit = SearchItem(
            id: "ocr:\(canonicalURL.path)",
            title: "fatura_2026.pdf",
            subtitle: "/tmp",
            category: .file,
            iconPath: canonicalURL.path,
            score: 640,
            action: .openFile(canonicalURL),
            previewURL: canonicalURL,
            matchedSnippet: "Fatura No 8842 · 1.250,00 TL",
            matchSource: .ocrContent
        )

        let fusedList = ResultRanker.mergeDeduplicatingFiles(ocr: [ocrHit], files: [spotlightHit])
        XCTAssertEqual(fusedList.count, 1)
        let fused = try XCTUnwrap(fusedList.first)
        XCTAssertEqual(fused.score, 890)
        XCTAssertEqual(fused.matchedSnippet, "Fatura No 8842 · 1.250,00 TL")
        XCTAssertEqual(fused.matchSource, .name)

        // Score ceiling at 990 for fusion bonus
        let highFused = try XCTUnwrap(
            ResultRanker.mergeDeduplicatingFiles(ocr: [ocrHit], files: [spotlightHit.withScore(960)]).first
        )
        XCTAssertEqual(highFused.score, 990)

        // 2. Diversity slot protection: 10 OCR + 8 apps + 10 Spotlight files -> top 18 preserves files & apps
        let apps = (0..<8).map { idx in
            let url = URL(fileURLWithPath: "/Applications/App\(idx).app")
            return SearchItem(
                id: "app:\(url.path)",
                title: "App\(idx)",
                subtitle: "/Applications",
                category: .application,
                score: 820 - idx * 5,
                action: .openFile(url),
                previewURL: url,
                matchSource: .name
            )
        }
        let ocrHits = (0..<10).map { idx in
            let url = URL(fileURLWithPath: "/tmp/ocr_\(idx).png")
            return SearchItem(
                id: "ocr:\(url.path)",
                title: "ocr_\(idx).png",
                subtitle: "/tmp",
                category: .file,
                score: 710 - idx * 5,
                action: .openFile(url),
                previewURL: url,
                matchedSnippet: "OCR match \(idx)",
                matchSource: .ocrContent
            )
        }
        let spotlightFiles = (0..<10).map { idx in
            let url = URL(fileURLWithPath: "/tmp/file_\(idx).pdf")
            return SearchItem(
                id: "file:\(url.path)",
                title: "file_\(idx).pdf",
                subtitle: "/tmp",
                category: .file,
                score: 640 - idx * 5,
                action: .openFile(url),
                previewURL: url,
                matchSource: .name
            )
        }

        let ranked = ResultRanker.mergeAndRank(
            query: "rapor",
            quickActions: [],
            apps: apps,
            recentFiles: [],
            ocrFiles: ocrHits,
            spotlightFiles: spotlightFiles,
            filter: nil,
            limit: 18
        )
        XCTAssertEqual(ranked.count, 18)
        XCTAssertEqual(ranked[0].id, apps[0].id)
        XCTAssertEqual(ranked[1].id, apps[1].id)

        let visibleSpotlightFiles = ranked.filter {
            ($0.category == .file || $0.category == .folder) && $0.matchSource != .ocrContent
        }
        let visibleApps = ranked.filter { $0.category == .application }
        let visibleOCR = ranked.filter { $0.matchSource == .ocrContent }

        XCTAssertGreaterThanOrEqual(visibleSpotlightFiles.count, 5)
        XCTAssertGreaterThanOrEqual(visibleApps.count, 3)
        XCTAssertGreaterThanOrEqual(visibleOCR.count, 3)

        // Filtered mode bypasses general diversity quotas and ranks strictly by score
        let filteredRanked = ResultRanker.mergeAndRank(
            query: "rapor",
            quickActions: [],
            apps: [],
            recentFiles: [],
            ocrFiles: ocrHits,
            spotlightFiles: spotlightFiles,
            filter: .filesOnly,
            limit: 10
        )
        XCTAssertEqual(filteredRanked.count, 10)
        XCTAssertTrue(filteredRanked.allSatisfy { $0.matchSource == .ocrContent })
    }
}
