import XCTest
@testable import QuickSpotCore

final class ConverterAndFilterTests: XCTestCase {
    func testColorTimestampAndUnitConverters() {
        let hex = ConverterAction.item(for: "#3B82F6")
        XCTAssertEqual(hex?.id, "color:3B82F6")
        XCTAssertEqual(hex?.title, "#3B82F6")
        XCTAssertEqual(hex?.subtitle.contains("rgb(59, 130, 246)"), true)

        let rgb = ConverterAction.item(for: "rgb(255, 0, 0)")
        XCTAssertEqual(rgb?.id, "color:FF0000")
        XCTAssertEqual(rgb?.title, "#FF0000")

        let ts = ConverterAction.item(for: "1731960000")
        XCTAssertNotNil(ts)
        XCTAssertEqual(ts?.subtitle.contains("2024-11-18T20:00:00Z"), true)

        let kmToMi = ConverterAction.item(for: "120 km to mi")
        XCTAssertEqual(kmToMi?.action, .copyText("74.5645"))

        let mbToGb = ConverterAction.item(for: "4096 mb to gb")
        XCTAssertEqual(mbToGb?.action, .copyText("4"))

        let cToF = ConverterAction.item(for: "0 c to f")
        XCTAssertEqual(cToF?.action, .copyText("32"))
    }

    func testSearchKindPrefixParsing() {
        let img = ImageOCRIndexer.parsePrefix("img: fatura")
        XCTAssertEqual(img.filter, .imagesOnly)
        XCTAssertEqual(img.cleanQuery, "fatura")

        let trImg = ImageOCRIndexer.parsePrefix("resim: ekran görüntüsü")
        XCTAssertEqual(trImg.filter, .imagesOnly)
        XCTAssertEqual(trImg.cleanQuery, "ekran görüntüsü")

        let pdf = ImageOCRIndexer.parsePrefix("pdf: sözleşme")
        XCTAssertEqual(pdf.filter, .pdfOnly)
        XCTAssertEqual(pdf.cleanQuery, "sözleşme")

        let plain = ImageOCRIndexer.parsePrefix("safari")
        XCTAssertNil(plain.filter)
        XCTAssertEqual(plain.cleanQuery, "safari")
    }

    func testNewSystemCommandsAndFrecencyTopIDs() {
        let settings = SystemCommandAction.match(query: "ayarlar")
        XCTAssertEqual(settings.first?.action, .openSettings)

        XCTAssertEqual(SystemCommandAction.match(query: "mute").first?.action, .systemCommand("mute"))
        XCTAssertEqual(SystemCommandAction.match(query: "screenshot").first?.action, .systemCommand("screenshot"))
        XCTAssertEqual(SystemCommandAction.match(query: "caffeinate").first?.action, .systemCommand("caffeinate"))

        let suite = "QuickSpotFrecency-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = FrecencyStore(defaults: defaults)
        store.record(id: "/Applications/Safari.app")
        store.record(id: "/Applications/Terminal.app")
        store.record(id: "/Applications/Terminal.app")
        XCTAssertEqual(store.topIDs(limit: 2), ["/Applications/Terminal.app", "/Applications/Safari.app"])
    }
}
