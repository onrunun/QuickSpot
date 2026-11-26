import Carbon
import Foundation

/// Snapshot of a single macOS system symbolic hotkey returned by `CopySymbolicHotKeys`.
public struct SystemSymbolicHotkey: Equatable, Sendable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32
    public let isEnabled: Bool

    public init(keyCode: UInt32, carbonModifiers: UInt32, isEnabled: Bool) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers & CarbonModifierMask.supported
        self.isEnabled = isEnabled
    }
}

/// Describes why a chosen global hotkey cannot currently trigger QuickSpot cleanly.
public enum HotkeyConflict: Equatable, Sendable {
    case spotlight
    case finderSearch
    case inputSource
    case emojiPicker
    case systemShortcut
    case registrationFailed

    public var isSpotlightConflict: Bool { self == .spotlight }

    public var canBeResolvedInKeyboardSettings: Bool {
        switch self {
        case .spotlight, .finderSearch, .inputSource, .emojiPicker, .systemShortcut:
            return true
        case .registrationFailed:
            return false
        }
    }

    public func localizedTitle(for shortcut: HotkeyShortcut) -> String {
        switch self {
        case .spotlight:
            return L10n.tr("hotkey.conflict.spotlight.title")
        case .finderSearch:
            return L10n.format("hotkey.conflict.finder_search.title", shortcut.displayString)
        case .inputSource:
            return L10n.format("hotkey.conflict.input_source.title", shortcut.displayString)
        case .emojiPicker:
            return L10n.format("hotkey.conflict.emoji.title", shortcut.displayString)
        case .systemShortcut:
            return L10n.format("hotkey.conflict.system.title", shortcut.displayString)
        case .registrationFailed:
            return L10n.format("hotkey.conflict.in_use.title", shortcut.displayString)
        }
    }

    public var localizedDetail: String {
        switch self {
        case .spotlight:
            return L10n.tr("hotkey.conflict.spotlight.detail")
        case .finderSearch:
            return L10n.tr("hotkey.conflict.finder_search.detail")
        case .inputSource:
            return L10n.tr("hotkey.conflict.input_source.detail")
        case .emojiPicker:
            return L10n.tr("hotkey.conflict.emoji.detail")
        case .systemShortcut:
            return L10n.tr("hotkey.conflict.system.detail")
        case .registrationFailed:
            return L10n.tr("hotkey.conflict.in_use.detail")
        }
    }
}

/// Inspects active macOS symbolic hotkeys via public Carbon `CopySymbolicHotKeys` (zero permissions required).
public enum SystemHotkeyInspector {
    public static let keyboardSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
    )!

    /// Reads the live macOS symbolic hotkey table from WindowServer.
    public static func systemHotkeys() -> [SystemSymbolicHotkey] {
        var unmanagedArray: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanagedArray) == noErr,
              let entries = unmanagedArray?.takeRetainedValue() as? [[String: Any]] else {
            return []
        }

        let codeKey = kHISymbolicHotKeyCode as String
        let modKey = kHISymbolicHotKeyModifiers as String
        let enabledKey = kHISymbolicHotKeyEnabled as String

        return entries.compactMap { entry in
            guard let rawCode = entry[codeKey] as? NSNumber,
                  let rawMods = entry[modKey] as? NSNumber,
                  let rawEnabled = entry[enabledKey] as? NSNumber else {
                return nil
            }
            return SystemSymbolicHotkey(
                keyCode: rawCode.uint32Value,
                carbonModifiers: rawMods.uint32Value,
                isEnabled: rawEnabled.boolValue
            )
        }
    }

    /// Returns the macOS system conflict for `shortcut`, or `nil` if no active system symbolic hotkey owns it.
    public static func conflict(
        for shortcut: HotkeyShortcut,
        systemHotkeys: [SystemSymbolicHotkey]? = nil
    ) -> HotkeyConflict? {
        let hotkeys = systemHotkeys ?? Self.systemHotkeys()
        let hasCollision = hotkeys.contains { entry in
            entry.isEnabled
                && entry.keyCode == shortcut.keyCode
                && entry.carbonModifiers == shortcut.carbonModifiers
        }
        guard hasCollision else { return nil }

        switch shortcut {
        case .cmdSpace:
            return .spotlight
        case .optionCmdSpace:
            return .finderSearch
        case .controlSpace, .controlOptionSpace:
            return .inputSource
        case .controlCmdSpace:
            return .emojiPicker
        default:
            return .systemShortcut
        }
    }

    /// True when macOS Spotlight currently holds `⌘Space`.
    public static func isSpotlightShortcutEnabled(
        systemHotkeys: [SystemSymbolicHotkey]? = nil
    ) -> Bool {
        conflict(for: .cmdSpace, systemHotkeys: systemHotkeys) == .spotlight
    }

    /// Picks a guaranteed conflict-free initial shortcut for fresh installs:
    /// uses `⌥Space` when Spotlight owns `⌘Space`, or `⌘Space` when Spotlight is already disabled.
    public static func recommendedInitialShortcut(
        systemHotkeys: [SystemSymbolicHotkey]? = nil
    ) -> HotkeyShortcut {
        let hotkeys = systemHotkeys ?? Self.systemHotkeys()
        if conflict(for: .cmdSpace, systemHotkeys: hotkeys) == nil {
            return .cmdSpace
        }
        return fallbackConflictFreeShortcut(systemHotkeys: hotkeys)
    }

    /// Picks the best conflict-free alternative shortcut for using QuickSpot alongside Spotlight.
    public static func fallbackConflictFreeShortcut(
        systemHotkeys: [SystemSymbolicHotkey]? = nil
    ) -> HotkeyShortcut {
        let hotkeys = systemHotkeys ?? Self.systemHotkeys()
        let candidates: [HotkeyShortcut] = [
            .optionSpace,
            .optionCmdSpace,
            HotkeyShortcut(keyCode: 49, carbonModifiers: CarbonModifierMask.option | CarbonModifierMask.shift),
            .controlSpace
        ]
        for candidate in candidates where conflict(for: candidate, systemHotkeys: hotkeys) == nil {
            return candidate
        }
        return .optionSpace
    }
}
