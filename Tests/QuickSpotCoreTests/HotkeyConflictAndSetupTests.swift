import Foundation
import XCTest
@testable import QuickSpotCore

final class HotkeyConflictAndSetupTests: XCTestCase {
    func testShortcutDisplayFormattingAndValidation() {
        XCTAssertEqual(HotkeyShortcut.cmdSpace.displayString, "⌘Space")
        XCTAssertEqual(HotkeyShortcut.optionSpace.displayString, "⌥Space")
        XCTAssertEqual(HotkeyShortcut.optionCmdSpace.displayString, "⌥⌘Space")

        let custom = HotkeyShortcut(
            keyCode: 40, // K
            carbonModifiers: CarbonModifierMask.control | CarbonModifierMask.shift
        )
        XCTAssertEqual(custom.displayString, "⌃⇧K")
        XCTAssertTrue(custom.isValid)
        XCTAssertNil(custom.matchingPreset)
        XCTAssertEqual(custom.usageMode, .alongsideSpotlight)

        XCTAssertEqual(HotkeyShortcut.cmdSpace.matchingPreset, .cmdSpace)
        XCTAssertEqual(HotkeyShortcut.cmdSpace.usageMode, .replaceSpotlight)
        XCTAssertEqual(HotkeyShortcut.optionSpace.matchingPreset, .optionSpace)
        XCTAssertEqual(HotkeyShortcut.optionCmdSpace.matchingPreset, .optionCmdSpace)

        // Reject bare keys, shift-only, modifier-only, Escape, ⌘Tab, and ⌘Q.
        XCTAssertFalse(HotkeyShortcut(keyCode: 49, carbonModifiers: 0).isValid)
        XCTAssertFalse(HotkeyShortcut(keyCode: 49, carbonModifiers: CarbonModifierMask.shift).isValid)
        XCTAssertFalse(HotkeyShortcut(keyCode: 55, carbonModifiers: CarbonModifierMask.command).isValid)
        XCTAssertFalse(HotkeyShortcut(keyCode: 53, carbonModifiers: CarbonModifierMask.command).isValid)
        XCTAssertFalse(HotkeyShortcut(keyCode: 48, carbonModifiers: CarbonModifierMask.command).isValid)
        XCTAssertFalse(HotkeyShortcut(keyCode: 12, carbonModifiers: CarbonModifierMask.command).isValid)
    }

    func testSystemConflictDetectionAndSmartInitialDefault() {
        let defaultMacOSHotkeys: [SystemSymbolicHotkey] = [
            SystemSymbolicHotkey(keyCode: 49, carbonModifiers: CarbonModifierMask.command, isEnabled: true),
            SystemSymbolicHotkey(
                keyCode: 49,
                carbonModifiers: CarbonModifierMask.option | CarbonModifierMask.command,
                isEnabled: true
            ),
            SystemSymbolicHotkey(keyCode: 49, carbonModifiers: CarbonModifierMask.control, isEnabled: true),
            SystemSymbolicHotkey(
                keyCode: 49,
                carbonModifiers: CarbonModifierMask.control | CarbonModifierMask.command,
                isEnabled: true
            )
        ]

        XCTAssertTrue(SystemHotkeyInspector.isSpotlightShortcutEnabled(systemHotkeys: defaultMacOSHotkeys))
        XCTAssertEqual(
            SystemHotkeyInspector.conflict(for: .cmdSpace, systemHotkeys: defaultMacOSHotkeys),
            .spotlight
        )
        XCTAssertEqual(
            SystemHotkeyInspector.conflict(for: .optionCmdSpace, systemHotkeys: defaultMacOSHotkeys),
            .finderSearch
        )
        XCTAssertEqual(
            SystemHotkeyInspector.conflict(for: .controlSpace, systemHotkeys: defaultMacOSHotkeys),
            .inputSource
        )
        XCTAssertEqual(
            SystemHotkeyInspector.conflict(for: .controlCmdSpace, systemHotkeys: defaultMacOSHotkeys),
            .emojiPicker
        )
        XCTAssertNil(SystemHotkeyInspector.conflict(for: .optionSpace, systemHotkeys: defaultMacOSHotkeys))

        // Fresh Mac with default Spotlight enabled -> never defaults to conflicting ⌘Space.
        XCTAssertEqual(
            SystemHotkeyInspector.recommendedInitialShortcut(systemHotkeys: defaultMacOSHotkeys),
            .optionSpace
        )

        // Mac where user already disabled Spotlight ⌘Space -> safe to default to ⌘Space.
        let spotlightDisabledHotkeys: [SystemSymbolicHotkey] = [
            SystemSymbolicHotkey(keyCode: 49, carbonModifiers: CarbonModifierMask.command, isEnabled: false)
        ]
        XCTAssertFalse(SystemHotkeyInspector.isSpotlightShortcutEnabled(systemHotkeys: spotlightDisabledHotkeys))
        XCTAssertNil(SystemHotkeyInspector.conflict(for: .cmdSpace, systemHotkeys: spotlightDisabledHotkeys))
        XCTAssertEqual(
            SystemHotkeyInspector.recommendedInitialShortcut(systemHotkeys: spotlightDisabledHotkeys),
            .cmdSpace
        )

        // If both ⌘Space and ⌥Space are taken, falls back to next free shortcut (⌥⌘Space).
        let crowdedHotkeys: [SystemSymbolicHotkey] = [
            SystemSymbolicHotkey(keyCode: 49, carbonModifiers: CarbonModifierMask.command, isEnabled: true),
            SystemSymbolicHotkey(keyCode: 49, carbonModifiers: CarbonModifierMask.option, isEnabled: true)
        ]
        XCTAssertEqual(
            SystemHotkeyInspector.recommendedInitialShortcut(systemHotkeys: crowdedHotkeys),
            .optionCmdSpace
        )
    }

    func testPreferencesStorePersistenceAndLegacyMigration() throws {
        let suiteName = "com.quickspot.tests.hotkey.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HotkeyPreferencesStore(defaults: defaults)
        XCTAssertFalse(store.hasCompletedOnboarding)
        XCTAssertNil(store.loadSavedShortcut())

        // Legacy v1.0.0 auto-saved cmdSpace on a Mac where Spotlight is active falls back cleanly pre-onboarding.
        let spotlightActive = [
            SystemSymbolicHotkey(keyCode: 49, carbonModifiers: CarbonModifierMask.command, isEnabled: true)
        ]
        defaults.set("cmdSpace", forKey: HotkeyPreferencesStore.legacyPresetKey)
        XCTAssertEqual(store.loadSavedShortcut(), .cmdSpace)
        XCTAssertEqual(store.resolveStartupShortcut(systemHotkeys: spotlightActive), .optionSpace)

        // Legacy optionSpace migrates directly.
        defaults.set("optionSpace", forKey: HotkeyPreferencesStore.legacyPresetKey)
        XCTAssertEqual(store.loadSavedShortcut(), .optionSpace)

        // Saving a custom shortcut persists keyCode + modifiers and clears legacy preset key.
        let custom = HotkeyShortcut(keyCode: 40, carbonModifiers: CarbonModifierMask.option | CarbonModifierMask.shift)
        store.saveShortcut(custom)
        store.hasCompletedOnboarding = true
        XCTAssertTrue(store.hasCompletedOnboarding)
        XCTAssertEqual(store.loadSavedShortcut(), custom)
        XCTAssertNil(defaults.string(forKey: HotkeyPreferencesStore.legacyPresetKey))
        XCTAssertEqual(store.resolveStartupShortcut(systemHotkeys: spotlightActive), custom)

        // Saving a preset restores legacy preset key as well.
        store.saveShortcut(.optionCmdSpace)
        XCTAssertEqual(store.loadSavedShortcut(), .optionCmdSpace)
        XCTAssertEqual(defaults.string(forKey: HotkeyPreferencesStore.legacyPresetKey), "optionCmdSpace")
    }
}
