import Foundation

/// Persists the user's chosen global shortcut (with legacy preset migration) and onboarding state.
public final class HotkeyPreferencesStore {
    public static let legacyPresetKey = "QuickSpot.hotkeyPreset"
    public static let shortcutKeyCodeKey = "QuickSpot.hotkeyShortcut.keyCode"
    public static let shortcutModifiersKey = "QuickSpot.hotkeyShortcut.modifiers"
    public static let onboardingCompletedKey = "QuickSpot.onboardingCompleted"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Self.onboardingCompletedKey) }
        set { defaults.set(newValue, forKey: Self.onboardingCompletedKey) }
    }

    /// Loads the saved shortcut, migrating legacy `QuickSpot.hotkeyPreset` values automatically.
    public func loadSavedShortcut() -> HotkeyShortcut? {
        if defaults.object(forKey: Self.shortcutKeyCodeKey) != nil,
           defaults.object(forKey: Self.shortcutModifiersKey) != nil {
            let keyCode = UInt32(max(0, defaults.integer(forKey: Self.shortcutKeyCodeKey)))
            let modifiers = UInt32(max(0, defaults.integer(forKey: Self.shortcutModifiersKey)))
            let shortcut = HotkeyShortcut(keyCode: keyCode, carbonModifiers: modifiers)
            if shortcut.isValid { return shortcut }
        }

        if let rawPreset = defaults.string(forKey: Self.legacyPresetKey),
           let preset = HotkeyPreset(rawValue: rawPreset) {
            return preset.shortcut
        }
        return nil
    }

    /// Persists the shortcut and keeps the legacy preset key synced when matching a built-in preset.
    public func saveShortcut(_ shortcut: HotkeyShortcut) {
        defaults.set(Int(shortcut.keyCode), forKey: Self.shortcutKeyCodeKey)
        defaults.set(Int(shortcut.carbonModifiers), forKey: Self.shortcutModifiersKey)
        if let preset = shortcut.matchingPreset {
            defaults.set(preset.rawValue, forKey: Self.legacyPresetKey)
        } else {
            defaults.removeObject(forKey: Self.legacyPresetKey)
        }
    }

    /// Resolves the startup shortcut cleanly without colliding with Spotlight on first launch.
    public func resolveStartupShortcut(
        systemHotkeys: [SystemSymbolicHotkey]? = nil
    ) -> HotkeyShortcut {
        if let saved = loadSavedShortcut() {
            // If a pre-onboarding v1.0.0 user had auto-saved `⌘Space` while Spotlight is actually active,
            // fall back cleanly to a conflict-free shortcut until they choose in Setup.
            if !hasCompletedOnboarding,
               saved == .cmdSpace,
               SystemHotkeyInspector.conflict(for: .cmdSpace, systemHotkeys: systemHotkeys) != nil {
                return SystemHotkeyInspector.fallbackConflictFreeShortcut(systemHotkeys: systemHotkeys)
            }
            return saved
        }
        return SystemHotkeyInspector.recommendedInitialShortcut(systemHotkeys: systemHotkeys)
    }
}
