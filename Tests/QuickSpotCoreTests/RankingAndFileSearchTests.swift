import Foundation
import XCTest
@testable import QuickSpotCore

final class RankingAndFileSearchTests: XCTestCase {
    // MARK: - QueryParser

    func testQueryParserEmptyTerminalPathFiltersAndGeneral() {
        XCTAssertEqual(QueryParser.parse("").mode, .empty)
        XCTAssertEqual(QueryParser.parse("   \t\n  ").mode, .empty)

        XCTAssertEqual(QueryParser.parse("> git status").mode, .terminal(command: "git status"))
        XCTAssertEqual(QueryParser.parse("$ ls -la").mode, .terminal(command: "ls -la"))
        XCTAssertEqual(QueryParser.parse(">").mode, .terminal(command: ""))

        XCTAssertEqual(QueryParser.parse("~").mode, .path(rawPath: "~"))
        XCTAssertEqual(QueryParser.parse("~/Downloads").mode, .path(rawPath: "~/Downloads"))
        XCTAssertEqual(QueryParser.parse("/tmp").mode, .path(rawPath: "/tmp"))
        XCTAssertEqual(QueryParser.parse("  /usr/local/bin  ").mode, .path(rawPath: "/usr/local/bin"))

        let filterCases: [(String, SearchKindFilter, String)] = [
            ("img: fatura", .imagesOnly, "fatura"),
            ("resim: ekran", .imagesOnly, "ekran"),
            ("gorsel: logo", .imagesOnly, "logo"),
            ("görsel: afiş", .imagesOnly, "afiş"),
            ("pdf: sözleşme", .pdfOnly, "sözleşme"),
            ("f: rapor", .filesOnly, "rapor"),
            ("file: notes", .filesOnly, "notes"),
            ("dosya: dilekce", .filesOnly, "dilekce"),
            ("dir: projects", .foldersOnly, "projects"),
            ("d: desktop", .foldersOnly, "desktop"),
            ("klasor: belgeler", .foldersOnly, "belgeler"),
            ("klasör: arşiv", .foldersOnly, "arşiv"),
            ("in: tazminat", .contentOnly, "tazminat"),
            ("icerik: karar", .contentOnly, "karar"),
            ("içerik: hüküm", .contentOnly, "hüküm"),
            ("app: safari", .appsOnly, "safari"),
            ("uyg: terminal", .appsOnly, "terminal"),
            ("PDF:   bilanço  ", .pdfOnly, "bilanço"),
            ("img:", .imagesOnly, "")
        ]

        for (raw, expectedFilter, expectedTerm) in filterCases {
            let parsed = QueryParser.parse(raw)
            XCTAssertEqual(
                parsed.mode,
                .filtered(filter: expectedFilter, term: expectedTerm),
                "Failed for input: \(raw)"
            )
        }

        XCTAssertEqual(QueryParser.parse("safari").mode, .general(term: "safari"))
        XCTAssertEqual(QueryParser.parse("  savunma dilekce  ").mode, .general(term: "savunma dilekce"))
    }

    // MARK: - FuzzyMatcher

    func testFuzzyMatcherNFDMultiTokenAndScoreFilename() {
        // macOS HFS+/APFS NFD decomposed Turkish filename
        let nfdName = "DI\u{0307}LEKC\u{0327}ESI\u{0307}.docx"
        XCTAssertEqual(FuzzyMatcher.normalize(nfdName), "dilekcesi.docx")

        let nfdScore = FuzzyMatcher.score(query: "dilekce", candidate: nfdName)
        XCTAssertNotNil(nfdScore)
        XCTAssertGreaterThanOrEqual(nfdScore ?? 0, 800)
        XCTAssertEqual(FuzzyMatcher.scoreFilename(query: "dilekcesi", fileName: nfdName), 1000)

        let nfdTurkishFull = "O\u{0308}G\u{0306}RENCI\u{0307}_S\u{0327}UBESI\u{0307}.pdf"
        let nfdMulti = FuzzyMatcher.score(query: "ogrenci subesi", candidate: nfdTurkishFull)
        XCTAssertNotNil(nfdMulti)
        XCTAssertGreaterThanOrEqual(nfdMulti ?? 0, 750)

        // Multi-token queries (in-order and out-of-order)
        let legalDoc = "2026_Savunma_3ACM_Dilekce.docx"
        let inOrder = FuzzyMatcher.score(query: "savunma dilekce", candidate: legalDoc)
        let outOfOrder = FuzzyMatcher.score(query: "dilekce savunma", candidate: legalDoc)
        XCTAssertNotNil(inOrder)
        XCTAssertNotNil(outOfOrder)
        XCTAssertGreaterThanOrEqual(inOrder ?? 0, 750)
        XCTAssertGreaterThanOrEqual(outOfOrder ?? 0, 700)
        XCTAssertGreaterThan(inOrder ?? 0, outOfOrder ?? 0)
        XCTAssertNil(FuzzyMatcher.score(query: "savunma olmayan", candidate: legalDoc))

        // Extension-stripped exact match via scoreFilename
        XCTAssertEqual(FuzzyMatcher.scoreFilename(query: "rapor", fileName: "rapor.pdf"), 1000)
        XCTAssertEqual(FuzzyMatcher.scoreFilename(query: "rapor.pdf", fileName: "rapor.pdf"), 1000)
        XCTAssertEqual(FuzzyMatcher.scoreFilename(query: "archive.tar", fileName: "archive.tar.gz"), 1000)
        XCTAssertEqual(FuzzyMatcher.scoreFilename(query: ".gitignore", fileName: ".gitignore"), 1000)
    }

    // MARK: - FrecencyStore

    func testFrecencyStoreLegacyMigrationDecayAndQueryAffinity() throws {
        // 1. Legacy [String: Int] migration on init
        let legacySuite = "QuickSpotLegacyFrecency-\(UUID().uuidString)"
        let legacyDefaults = try XCTUnwrap(UserDefaults(suiteName: legacySuite))
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }

        legacyDefaults.set(
            ["/Applications/Safari.app": 5, "/Applications/Notes.app": 2, "/tmp/ignored.txt": 0],
            forKey: "QuickSpot.frecency"
        )
        let migratedStore = FrecencyStore(defaults: legacyDefaults)
        XCTAssertEqual(migratedStore.topIDs(limit: 5), ["/Applications/Safari.app", "/Applications/Notes.app"])
        XCTAssertGreaterThan(
            migratedStore.boost(for: "/Applications/Safari.app"),
            migratedStore.boost(for: "/Applications/Notes.app")
        )
        XCTAssertNotNil(legacyDefaults.data(forKey: "QuickSpot.frecency"))

        let reloaded = FrecencyStore(defaults: legacyDefaults)
        XCTAssertEqual(reloaded.topIDs(limit: 5), ["/Applications/Safari.app", "/Applications/Notes.app"])

        // 2. Time-decayed boost (recent beats old) & topFileIDs filtering out apps/commands
        let decaySuite = "QuickSpotDecayFrecency-\(UUID().uuidString)"
        let decayDefaults = try XCTUnwrap(UserDefaults(suiteName: decaySuite))
        defer { decayDefaults.removePersistentDomain(forName: decaySuite) }

        let now = Date().timeIntervalSince1970
        let payload: [String: Any] = [
            "version": 2,
            "items": [
                "/Users/test/Documents/old.pdf": [
                    "count": 6, "decayedScore": 6.0, "lastUsed": now - 60.0 * 86_400.0
                ],
                "/Users/test/Documents/recent.pdf": [
                    "count": 2, "decayedScore": 2.0, "lastUsed": now - 3_600.0
                ],
                "/Applications/Safari.app": [
                    "count": 10, "decayedScore": 10.0, "lastUsed": now
                ],
                "sys:darkmode": [
                    "count": 10, "decayedScore": 10.0, "lastUsed": now
                ]
            ],
            "affinities": [:]
        ]
        let encoded = try JSONSerialization.data(withJSONObject: payload)
        decayDefaults.set(encoded, forKey: "QuickSpot.frecency")

        let decayStore = FrecencyStore(defaults: decayDefaults)
        XCTAssertGreaterThan(
            decayStore.boost(for: "/Users/test/Documents/recent.pdf"),
            decayStore.boost(for: "/Users/test/Documents/old.pdf")
        )
        XCTAssertEqual(
            decayStore.topFileIDs(limit: 5),
            ["/Users/test/Documents/recent.pdf", "/Users/test/Documents/old.pdf"]
        )

        // 3. Query-to-item affinity ("te" -> Terminal outranks globally high-count Telegram)
        let affinitySuite = "QuickSpotAffinityFrecency-\(UUID().uuidString)"
        let affinityDefaults = try XCTUnwrap(UserDefaults(suiteName: affinitySuite))
        defer { affinityDefaults.removePersistentDomain(forName: affinitySuite) }

        let affinityStore = FrecencyStore(defaults: affinityDefaults)
        let telegram = "/Applications/Telegram.app"
        let terminal = "/System/Applications/Utilities/Terminal.app"

        for _ in 0..<20 {
            affinityStore.record(id: telegram)
        }
        affinityStore.record(id: terminal, query: "te")

        // Globally Telegram has higher frecency
        XCTAssertGreaterThan(affinityStore.boost(for: telegram), affinityStore.boost(for: terminal))

        // For query "te", a single Terminal affinity binding outranks globally high-count Telegram
        let termBase = try XCTUnwrap(FuzzyMatcher.score(query: "te", candidate: "Terminal"))
        let teleBase = try XCTUnwrap(FuzzyMatcher.score(query: "te", candidate: "Telegram"))
        let termTotal = termBase + affinityStore.boost(for: terminal, query: "te")
        let teleTotal = teleBase + affinityStore.boost(for: telegram, query: "te")
        XCTAssertGreaterThan(termTotal, teleTotal)
        XCTAssertGreaterThan(
            affinityStore.boost(for: terminal, query: "ter"),
            affinityStore.boost(for: terminal, query: nil)
        )
    }
}
