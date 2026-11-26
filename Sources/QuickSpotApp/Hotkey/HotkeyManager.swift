import Carbon
import Foundation
import QuickSpotCore

/// Global hotkey presets supported by QuickSpot via Carbon RegisterEventHotKey.
enum HotkeyPreset: String, CaseIterable {
    case cmdSpace = "cmdSpace"
    case optionSpace = "optionSpace"

    var title: String {
        switch self {
        case .cmdSpace: return L10n.tr("hotkey.cmd_space")
        case .optionSpace: return L10n.tr("hotkey.option_space")
        }
    }

    var keyCode: UInt32 { 49 } // Spacebar

    var carbonModifiers: UInt32 {
        switch self {
        case .cmdSpace: return UInt32(cmdKey)
        case .optionSpace: return UInt32(optionKey)
        }
    }
}

/// Registers and switches a zero-polling global Carbon hotkey that persists across launches.
final class HotkeyManager {
    private static let presetKey = "QuickSpot.hotkeyPreset"
    private static let signature = OSType(0x5153_5054) // "QSPT"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let defaults: UserDefaults

    private(set) var currentPreset: HotkeyPreset
    var onPress: () -> Void = {}

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.presetKey).flatMap(HotkeyPreset.init(rawValue:))
        self.currentPreset = saved ?? .cmdSpace
    }

    deinit {
        unregister()
    }

    @discardableResult
    func register(preset: HotkeyPreset? = nil) -> Bool {
        let target = preset ?? currentPreset
        unregister()

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), hotkeyCallback, 1, &spec, selfPtr, &handlerRef) == noErr else {
            return false
        }

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            target.keyCode,
            target.carbonModifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            unregister()
            return false
        }

        currentPreset = target
        defaults.set(target.rawValue, forKey: Self.presetKey)
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    fileprivate func handlePress() {
        onPress()
    }
}

private func hotkeyCallback(
    _ next: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let ptr = UnsafeRawPointer(userData)
    MainActor.assumeIsolated {
        let manager = Unmanaged<HotkeyManager>.fromOpaque(ptr).takeUnretainedValue()
        manager.handlePress()
    }
    return noErr
}
