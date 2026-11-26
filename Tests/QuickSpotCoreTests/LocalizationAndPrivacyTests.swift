import Foundation
import XCTest
@testable import QuickSpotCore

final class LocalizationAndPrivacyTests: XCTestCase {
    func testAllLanguagesHaveCompleteKeysAndMatchingFormatSpecifiers() throws {
        let base = try XCTUnwrap(L10n.allStrings(for: .en), "Missing en.lproj/Localizable.strings")
        XCTAssertGreaterThanOrEqual(base.count, 100)

        let baseKeys = Set(base.keys)
        for language in AppLanguage.concreteLanguages {
            let table = try XCTUnwrap(
                L10n.allStrings(for: language),
                "Missing Localizable.strings for \(language.rawValue)"
            )
            let langKeys = Set(table.keys)
            let missing = baseKeys.subtracting(langKeys).sorted()
            let extra = langKeys.subtracting(baseKeys).sorted()
            XCTAssertTrue(missing.isEmpty, "\(language.rawValue) missing keys: \(missing)")
            XCTAssertTrue(extra.isEmpty, "\(language.rawValue) unexpected extra keys: \(extra)")

            for key in baseKeys {
                let value = table[key] ?? ""
                XCTAssertFalse(
                    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(language.rawValue) has empty value for key '\(key)'"
                )
                let expectedSpecs = extractFormatSpecifiers(base[key] ?? "")
                let actualSpecs = extractFormatSpecifiers(value)
                XCTAssertEqual(
                    actualSpecs,
                    expectedSpecs,
                    "\(language.rawValue) format specifier mismatch for '\(key)': expected \(expectedSpecs), got \(actualSpecs)"
                )
            }
        }
    }

    func testSystemLanguageResolutionAndFallback() {
        XCTAssertEqual(L10n.resolveSystemLanguage(preferredLanguages: ["en-US"]), .en)
        XCTAssertEqual(L10n.resolveSystemLanguage(preferredLanguages: ["tr-TR", "en-US"]), .tr)
        XCTAssertEqual(L10n.resolveSystemLanguage(preferredLanguages: ["de-AT"]), .de)
        XCTAssertEqual(L10n.resolveSystemLanguage(preferredLanguages: ["es-MX"]), .es)
        XCTAssertEqual(L10n.resolveSystemLanguage(preferredLanguages: ["fr-CA"]), .fr)
        XCTAssertEqual(L10n.resolveSystemLanguage(preferredLanguages: ["ja-JP"]), .ja)
        XCTAssertEqual(L10n.resolveSystemLanguage(preferredLanguages: ["zh-CN"]), .zhHans)
        XCTAssertEqual(L10n.resolveSystemLanguage(preferredLanguages: ["zh-Hans-SG"]), .zhHans)
        XCTAssertEqual(L10n.resolveSystemLanguage(preferredLanguages: ["pt-PT"]), .ptBR)
        XCTAssertEqual(L10n.resolveSystemLanguage(preferredLanguages: ["nl-NL", "sv-SE"]), .en)
    }

    func testMultilingualSystemCommandsAndLocalizedTitles() {
        XCTAssertEqual(SystemCommandAction.match(query: "sperren").first?.id, "sys:lock")
        XCTAssertEqual(SystemCommandAction.match(query: "dunkelmodus").first?.id, "sys:darkmode")
        XCTAssertEqual(SystemCommandAction.match(query: "bloquear").first?.id, "sys:lock")
        XCTAssertEqual(SystemCommandAction.match(query: "verrouiller").first?.id, "sys:lock")
        XCTAssertEqual(SystemCommandAction.match(query: "ダークモード").first?.id, "sys:darkmode")
        XCTAssertEqual(SystemCommandAction.match(query: "深色模式").first?.id, "sys:darkmode")
        XCTAssertEqual(SystemCommandAction.match(query: "configuracoes").first?.id, "sys:settings")

        let enTitle = L10n.withLanguage(.en) {
            SystemCommandAction.match(query: "lock").first?.title
        }
        XCTAssertEqual(enTitle, "Lock Screen")

        let jaTitle = L10n.withLanguage(.ja) {
            SystemCommandAction.match(query: "lock").first?.title
        }
        XCTAssertEqual(jaTitle, "画面をロック")
    }

    func testMultilingualFuzzyFoldingPrefixesAndCalculatorPrepositions() {
        XCTAssertNotNil(FuzzyMatcher.score(query: "strasse", candidate: "Straße"))
        XCTAssertNotNil(FuzzyMatcher.score(query: "resume", candidate: "Résumé"))
        XCTAssertNotNil(FuzzyMatcher.score(query: "nino", candidate: "Niño"))

        XCTAssertEqual(QueryParser.parse("bild: urlaub").mode, .filtered(filter: .imagesOnly, term: "urlaub"))
        XCTAssertEqual(QueryParser.parse("ordner: projekte").mode, .filtered(filter: .foldersOnly, term: "projekte"))
        XCTAssertEqual(QueryParser.parse("archivo: factura").mode, .filtered(filter: .filesOnly, term: "factura"))
        XCTAssertEqual(QueryParser.parse("dossier: travail").mode, .filtered(filter: .foldersOnly, term: "travail"))
        XCTAssertEqual(QueryParser.parse("pasta: fotos").mode, .filtered(filter: .foldersOnly, term: "fotos"))

        XCTAssertEqual(CalculatorAction.evaluate("20% von 500")?.result, "100")
        XCTAssertEqual(CalculatorAction.evaluate("10% de 250")?.result, "25")
        XCTAssertEqual(ConverterAction.item(for: "100 km zu mi")?.action, .copyText("62.1371"))
    }

    func testSensitiveFilesExcludedFromPreviewAndTerminalSanitization() throws {
        let dir = FileManager.default.temporaryDirectory
        let envURL = dir.appendingPathComponent(".env")
        let envProdURL = dir.appendingPathComponent(".env.production")
        let pemURL = dir.appendingPathComponent("quickspot-test-\(UUID().uuidString).pem")
        defer {
            try? FileManager.default.removeItem(at: envURL)
            try? FileManager.default.removeItem(at: envProdURL)
            try? FileManager.default.removeItem(at: pemURL)
        }

        try "SECRET_API_KEY=supersecret\n".write(to: envURL, atomically: true, encoding: .utf8)
        try "TOKEN=12345\n".write(to: envProdURL, atomically: true, encoding: .utf8)
        try "-----BEGIN PRIVATE KEY-----\n".write(to: pemURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(FileMetadataInspector.isSensitiveFile(envURL))
        XCTAssertTrue(FileMetadataInspector.isSensitiveFile(envProdURL))
        XCTAssertTrue(FileMetadataInspector.isSensitiveFile(pemURL))
        XCTAssertFalse(FileMetadataInspector.isTextOrCode(envURL))
        XCTAssertFalse(FileMetadataInspector.isTextOrCode(envProdURL))
        XCTAssertFalse(FileMetadataInspector.isTextOrCode(pemURL))
        XCTAssertNil(FileMetadataInspector.loadTextSnippet(envURL))
        XCTAssertNil(FileMetadataInspector.loadTextSnippet(pemURL))

        let sanitized = WebAndTerminalAction.sanitizeTerminalCommand("echo hi\nend tell\rdo shell script \"evil\"")
        XCTAssertFalse(sanitized.contains("\n"))
        XCTAssertFalse(sanitized.contains("\r"))
    }

    private func extractFormatSpecifiers(_ string: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"%[@dfu]"#) else { return [] }
        let range = NSRange(string.startIndex..., in: string)
        return regex.matches(in: string, range: range).compactMap {
            Range($0.range, in: string).map { String(string[$0]) }
        }
    }
}
