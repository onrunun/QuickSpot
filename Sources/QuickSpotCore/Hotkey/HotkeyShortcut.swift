import Foundation

/// Standard Carbon modifier bitmasks shared between `RegisterEventHotKey` and `CopySymbolicHotKeys`.
public enum CarbonModifierMask {
    public static let command: UInt32 = 0x0100  // cmdKey
    public static let shift: UInt32 = 0x0200    // shiftKey
    public static let option: UInt32 = 0x0800   // optionKey
    public static let control: UInt32 = 0x1000  // controlKey
    public static let supported: UInt32 = command | shift | option | control
}

/// Built-in global hotkey presets covering alongside-Spotlight and replace-Spotlight workflows.
public enum HotkeyPreset: String, CaseIterable, Sendable {
    case optionSpace = "optionSpace"
    case cmdSpace = "cmdSpace"
    case optionCmdSpace = "optionCmdSpace"

    public var shortcut: HotkeyShortcut {
        switch self {
        case .optionSpace: return .optionSpace
        case .cmdSpace: return .cmdSpace
        case .optionCmdSpace: return .optionCmdSpace
        }
    }

    public var title: String {
        switch self {
        case .cmdSpace: return L10n.tr("hotkey.cmd_space")
        case .optionSpace: return L10n.tr("hotkey.option_space")
        case .optionCmdSpace: return L10n.tr("hotkey.option_cmd_space")
        }
    }

    public var shortLabel: String { shortcut.displayString }
}

/// High-level workflow mode chosen in onboarding or inferred from the active shortcut.
public enum HotkeyUsageMode: String, Equatable, Sendable {
    case alongsideSpotlight
    case replaceSpotlight
}

/// Immutable representation of a global macOS keyboard shortcut (Carbon virtual key code + modifiers).
public struct HotkeyShortcut: Codable, Equatable, Hashable, Sendable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32

    public static let cmdSpace = HotkeyShortcut(keyCode: 49, carbonModifiers: CarbonModifierMask.command)
    public static let optionSpace = HotkeyShortcut(keyCode: 49, carbonModifiers: CarbonModifierMask.option)
    public static let optionCmdSpace = HotkeyShortcut(
        keyCode: 49,
        carbonModifiers: CarbonModifierMask.option | CarbonModifierMask.command
    )
    public static let controlSpace = HotkeyShortcut(keyCode: 49, carbonModifiers: CarbonModifierMask.control)
    public static let controlOptionSpace = HotkeyShortcut(
        keyCode: 49,
        carbonModifiers: CarbonModifierMask.control | CarbonModifierMask.option
    )
    public static let controlCmdSpace = HotkeyShortcut(
        keyCode: 49,
        carbonModifiers: CarbonModifierMask.control | CarbonModifierMask.command
    )

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers & CarbonModifierMask.supported
    }

    /// True when the shortcut uses a safe modifier combination suitable for a global hotkey.
    public var isValid: Bool {
        let primaryMask = CarbonModifierMask.command | CarbonModifierMask.option | CarbonModifierMask.control
        guard (carbonModifiers & primaryMask) != 0 else { return false }
        // Disallow bare modifier keys, Escape (cancels recorder), and critical macOS app-switch/quit combos.
        if Self.modifierKeyCodes.contains(keyCode) || keyCode == 53 { return false }
        if keyCode == 48 && carbonModifiers == CarbonModifierMask.command { return false } // ⌘Tab
        if keyCode == 12 && carbonModifiers == CarbonModifierMask.command { return false } // ⌘Q
        return true
    }

    public var matchingPreset: HotkeyPreset? {
        HotkeyPreset.allCases.first { $0.shortcut == self }
    }

    public var usageMode: HotkeyUsageMode {
        self == .cmdSpace ? .replaceSpotlight : .alongsideSpotlight
    }

    /// Human-readable macOS shortcut representation (e.g. `⌥Space`, `⌘Space`, `⌃⇧K`).
    public var displayString: String {
        var result = ""
        if (carbonModifiers & CarbonModifierMask.control) != 0 { result.append("⌃") }
        if (carbonModifiers & CarbonModifierMask.option) != 0 { result.append("⌥") }
        if (carbonModifiers & CarbonModifierMask.shift) != 0 { result.append("⇧") }
        if (carbonModifiers & CarbonModifierMask.command) != 0 { result.append("⌘") }
        result.append(Self.keyLabel(for: keyCode))
        return result
    }

    private static let modifierKeyCodes: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    public static func keyLabel(for keyCode: UInt32) -> String {
        keyCodeLabels[keyCode] ?? "Key\(keyCode)"
    }

    private static let keyCodeLabels: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
        42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥",
        49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        64: "F17", 65: ".", 67: "*", 69: "+", 71: "⌧", 75: "/", 76: "⌤", 78: "-",
        79: "F18", 80: "F19", 81: "=", 82: "0", 83: "1", 84: "2", 85: "3", 86: "4",
        87: "5", 88: "6", 89: "7", 90: "F20", 91: "8", 92: "9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10",
        111: "F12", 113: "F15", 115: "↖", 116: "⇞", 117: "⌦", 118: "F4",
        119: "↘", 120: "F2", 121: "⇟", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}
