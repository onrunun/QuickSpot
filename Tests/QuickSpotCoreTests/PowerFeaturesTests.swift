import Foundation
import XCTest
@testable import QuickSpotCore

final class PowerFeaturesTests: XCTestCase {
    func testSystemSettingsPanesTurkishAndEnglishMatching() {
        let wifi = SystemSettingsAction.match(query: "wifi")
        XCTAssertEqual(wifi.first?.id, "pref:wifi")
        if case .openURL(let url) = wifi.first?.action {
            XCTAssertEqual(url.absoluteString, "x-apple.systempreferences:com.apple.wifi-settings-extension")
        } else {
            XCTFail("Expected openURL action for Wi-Fi settings pane")
        }

        let bt = SystemSettingsAction.match(query: "bluetooth")
        XCTAssertEqual(bt.first?.id, "pref:bluetooth")

        let sound = SystemSettingsAction.match(query: "ses")
        XCTAssertTrue(sound.contains(where: { $0.id == "pref:sound" }))

        let displays = SystemSettingsAction.match(query: "ekran")
        XCTAssertTrue(displays.contains(where: { $0.id == "pref:displays" }))

        let storage = SystemSettingsAction.match(query: "depolama")
        XCTAssertEqual(storage.first?.id, "pref:storage")

        // Every configured pane must resolve to a valid x-apple.systempreferences URL.
        for pane in SystemSettingsAction.panes {
            let url = URL(string: pane.urlString)
            XCTAssertEqual(url?.scheme, "x-apple.systempreferences", "Invalid URL for pane \(pane.id)")
        }

        // Exact match calibrated at 910 (below exact app 1000+ and below exact recent file 960+).
        XCTAssertLessThanOrEqual(wifi.first?.score ?? 9999, 950)
    }

    func testClipboardPrivacyFilterBlocksPasswordManagersAndConcealedTypes() {
        XCTAssertFalse(ClipboardHistoryStore.shouldRecord(
            pasteboardTypes: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"],
            sourceBundleID: "com.apple.Safari"
        ))
        XCTAssertFalse(ClipboardHistoryStore.shouldRecord(
            pasteboardTypes: ["public.utf8-plain-text", "org.nspasteboard.TransientType"],
            sourceBundleID: "com.apple.Terminal"
        ))
        XCTAssertFalse(ClipboardHistoryStore.shouldRecord(
            pasteboardTypes: ["public.utf8-plain-text"],
            sourceBundleID: "com.apple.Passwords"
        ))
        XCTAssertFalse(ClipboardHistoryStore.shouldRecord(
            pasteboardTypes: ["public.utf8-plain-text"],
            sourceBundleID: "com.1password.1password"
        ))
        XCTAssertTrue(ClipboardHistoryStore.shouldRecord(
            pasteboardTypes: ["public.utf8-plain-text"],
            sourceBundleID: "com.apple.Safari"
        ))
    }

    func testClipboardHistoryRecordDeduplicateSearchDeleteAndQueryParser() {
        let suite = "QuickSpotClipboard-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickspot-clip-\(UUID().uuidString).json")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: storageURL)
        }

        let store = ClipboardHistoryStore(storageURL: storageURL, defaults: defaults)
        XCTAssertTrue(store.recordText("İlk kopyalanan metin", sourceApp: "Safari", timestamp: 100))
        XCTAssertTrue(store.recordText("https://github.com/quickspot", sourceApp: "Firefox", timestamp: 200))
        XCTAssertTrue(store.recordText("İlk kopyalanan metin", sourceApp: "Notes", timestamp: 300))
        XCTAssertFalse(store.recordText("   \n  "))

        XCTAssertEqual(store.count, 2, "Duplicate text should move to top rather than duplicate")
        let all = store.search(query: "")
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.action, .copyText("İlk kopyalanan metin"))
        XCTAssertEqual(all.first?.matchSource, .clipboard)

        let gh = store.search(query: "github")
        XCTAssertEqual(gh.count, 1)
        XCTAssertEqual(gh.first?.action, .copyText("https://github.com/quickspot"))

        let firstID = String((all.first?.id ?? "").dropFirst(5))
        store.delete(entryID: firstID)
        XCTAssertEqual(store.count, 1)

        store.clearAll()
        XCTAssertEqual(store.count, 0)

        XCTAssertEqual(QueryParser.parse("cb: fatura").mode, .filtered(filter: .clipboard, term: "fatura"))
        XCTAssertEqual(QueryParser.parse("pano:").mode, .filtered(filter: .clipboard, term: ""))
        XCTAssertEqual(QueryParser.parse("clip: link").mode, .filtered(filter: .clipboard, term: "link"))
    }

    func testFileActionServiceApplicationsShellQuoteAndMoveToTrash() throws {
        XCTAssertEqual(FileActionService.shellQuote("/Users/test/My Folder/a'b.txt"), "'/Users/test/My Folder/a'\\''b.txt'")

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickspot-trash-\(UUID().uuidString).txt")
        try "hello quickspot".write(to: tempFile, atomically: true, encoding: .utf8)

        let apps = FileActionService.applicationsForOpening(tempFile, limit: 6)
        XCTAssertFalse(apps.isEmpty, "macOS should return at least one handler for .txt files")

        let trashResult = FileActionService.moveToTrash(tempFile)
        switch trashResult {
        case .success(let trashedURL):
            XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path))
            if let trashedURL {
                try? FileManager.default.removeItem(at: trashedURL)
            }
        case .failure(let error):
            XCTFail("Expected moveToTrash to succeed: \(error)")
        }
    }
}
