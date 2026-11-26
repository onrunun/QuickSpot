import XCTest
@testable import QuickSpotCore

final class QuickSpotCoreTests: XCTestCase {
    func testFuzzyMatcherTurkishFoldingAndAcronyms() {
        let trScore = FuzzyMatcher.score(query: "karanlik", candidate: "Karanlık Mod")
        XCTAssertNotNil(trScore)
        XCTAssertGreaterThanOrEqual(trScore ?? 0, 800)

        let acronymScore = FuzzyMatcher.score(query: "vsc", candidate: "Visual Studio Code")
        XCTAssertNotNil(acronymScore)
        XCTAssertGreaterThanOrEqual(acronymScore ?? 0, 700)

        let camelAcronym = FuzzyMatcher.score(query: "qs", candidate: "QuickSpot")
        XCTAssertNotNil(camelAcronym)
        XCTAssertGreaterThanOrEqual(camelAcronym ?? 0, 700)

        XCTAssertNil(FuzzyMatcher.score(query: "zzzz", candidate: "Safari"))
    }

    func testCalculatorMathAndPercentages() {
        XCTAssertEqual(CalculatorAction.evaluate("2 + 3 * 4")?.result, "14")
        XCTAssertEqual(CalculatorAction.evaluate("2^10")?.result, "1024")
        XCTAssertEqual(CalculatorAction.evaluate("20% of 450")?.result, "90")
        XCTAssertEqual(CalculatorAction.evaluate("1500 + 18%")?.result, "1770")
        XCTAssertEqual(CalculatorAction.evaluate("1000 - 25%")?.result, "750")
        XCTAssertEqual(CalculatorAction.evaluate("sqrt(81)")?.result, "9")
        XCTAssertNil(CalculatorAction.evaluate("42"))
        XCTAssertNil(CalculatorAction.evaluate("safari"))
    }

    func testWebURLVsFilenameAndTerminalDetection() {
        XCTAssertEqual(WebAndTerminalAction.detectURL("github.com")?.absoluteString, "https://github.com")
        XCTAssertEqual(WebAndTerminalAction.detectURL("localhost:3000")?.absoluteString, "http://localhost:3000")
        XCTAssertNil(WebAndTerminalAction.detectURL("main.py"))
        XCTAssertNil(WebAndTerminalAction.detectURL("Package.swift"))
        XCTAssertNil(WebAndTerminalAction.detectURL("readme.md"))

        let term = WebAndTerminalAction.detectTerminal("> git status")
        XCTAssertEqual(term?.action, .runTerminal("git status"))
    }

    func testSystemCommandsTurkishAndEnglish() {
        let lockMatches = SystemCommandAction.match(query: "kilit")
        XCTAssertEqual(lockMatches.first?.action, .systemCommand("lock"))

        let darkMatches = SystemCommandAction.match(query: "karan")
        XCTAssertEqual(darkMatches.first?.action, .systemCommand("darkmode"))

        let ipMatches = SystemCommandAction.match(query: "ip")
        XCTAssertEqual(ipMatches.first?.id, "sys:ip")
    }

    func testQuickActionRouterExcludesAIAndDetectsFallback() {
        let questionActions = QuickActionRouter.generate(for: "? merhaba", localHits: [])
        XCTAssertEqual(questionActions.first?.id, "web:? merhaba")

        let urlActions = QuickActionRouter.generate(for: "apple.com", localHits: [])
        XCTAssertEqual(urlActions.first?.id, "url:https://apple.com")

        let calcActions = QuickActionRouter.generate(for: "2 + 2", localHits: [])
        XCTAssertEqual(calcActions.first?.action, .copyText("4"))

        let termActions = QuickActionRouter.generate(for: "> ls -la", localHits: [])
        XCTAssertEqual(termActions.first?.action, .runTerminal("ls -la"))
    }

    func testFileMetadataAndSnippetInspector() throws {
        let dir = FileManager.default.temporaryDirectory
        let swiftURL = dir.appendingPathComponent("quickspot-\(UUID().uuidString).swift")
        let binURL = dir.appendingPathComponent("quickspot-\(UUID().uuidString).bin")
        defer {
            try? FileManager.default.removeItem(at: swiftURL)
            try? FileManager.default.removeItem(at: binURL)
        }

        try "let x = 1\nlet y = 2\n".write(to: swiftURL, atomically: true, encoding: .utf8)
        try Data([0x00, 0xFF, 0x10]).write(to: binURL)

        XCTAssertTrue(FileMetadataInspector.isTextOrCode(swiftURL))
        XCTAssertFalse(FileMetadataInspector.isTextOrCode(binURL))
        XCTAssertEqual(FileMetadataInspector.loadTextSnippet(swiftURL), ["let x = 1", "let y = 2"])
        XCTAssertNil(FileMetadataInspector.loadTextSnippet(binURL))

        let meta = FileMetadataInspector.inspect(swiftURL)
        XCTAssertFalse(meta.detailsLine.isEmpty)
        XCTAssertNotNil(meta.sizeLabel)

        let calcURL = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        if FileManager.default.fileExists(atPath: calcURL.path) {
            let enMeta = L10n.withLanguage(.en) { FileMetadataInspector.inspect(calcURL) }
            XCTAssertEqual(enMeta.kindLabel, "Application")
            let trMeta = L10n.withLanguage(.tr) { FileMetadataInspector.inspect(calcURL) }
            XCTAssertEqual(trMeta.kindLabel, "Uygulama")
        }
    }
}
