import AppKit
import Carbon
import Foundation
import QuickSpotCore

/// Manages global Carbon hotkey registration, custom shortcuts, and live macOS conflict detection.
@MainActor
final class HotkeyManager: ObservableObject {
    private static let signature = OSType(0x5153_5054) // "QSPT"

    let preferencesStore: HotkeyPreferencesStore

    @Published private(set) var currentShortcut: HotkeyShortcut
    @Published private(set) var activeConflict: HotkeyConflict?
    @Published private(set) var isRegistered: Bool = false
    @Published private(set) var isSpotlightShortcutEnabled: Bool

    var onPress: () -> Void = {}
    var onStateChange: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var isSuspendedForRecording = false
    private var liveMonitorCount = 0
    private var conflictPollTimer: Timer?

    init(preferencesStore: HotkeyPreferencesStore = HotkeyPreferencesStore()) {
        self.preferencesStore = preferencesStore
        let systemHotkeys = SystemHotkeyInspector.systemHotkeys()
        self.isSpotlightShortcutEnabled = SystemHotkeyInspector.isSpotlightShortcutEnabled(
            systemHotkeys: systemHotkeys
        )
        self.currentShortcut = preferencesStore.resolveStartupShortcut(systemHotkeys: systemHotkeys)
    }

    deinit {
        conflictPollTimer?.invalidate()
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Registers the initial startup shortcut without conflicting with Spotlight.
    @discardableResult
    func registerInitial() -> Bool {
        applyShortcut(currentShortcut, persist: false)
    }

    /// Selects and persists a preset shortcut (`⌥Space`, `⌘Space`, `⌥⌘Space`).
    @discardableResult
    func selectPreset(_ preset: HotkeyPreset) -> Bool {
        select(preset.shortcut, persist: true)
    }

    /// Selects and persists any valid custom or preset shortcut, checking macOS conflicts first.
    @discardableResult
    func select(_ shortcut: HotkeyShortcut, persist: Bool = true) -> Bool {
        guard shortcut.isValid else { return false }
        return applyShortcut(shortcut, persist: persist)
    }

    /// Switches immediately to the best available conflict-free alongside-Spotlight shortcut (`⌥Space`).
    @discardableResult
    func switchToConflictFreeAlternative() -> Bool {
        let fallback = SystemHotkeyInspector.fallbackConflictFreeShortcut()
        return select(fallback, persist: true)
    }

    /// Temporarily pauses global hotkey interception while the user records a new custom shortcut.
    func suspendForRecording() {
        guard !isSuspendedForRecording else { return }
        isSuspendedForRecording = true
        unregisterCarbon()
    }

    /// Resumes global hotkey registration after shortcut recording finishes or cancels.
    func resumeAfterRecording() {
        guard isSuspendedForRecording else { return }
        isSuspendedForRecording = false
        _ = applyShortcut(currentShortcut, persist: false)
    }

    /// Re-checks macOS symbolic hotkeys and automatically binds or flags conflicts when state changes.
    func refreshSystemStatus() {
        let systemHotkeys = SystemHotkeyInspector.systemHotkeys()
        let spotlightEnabled = SystemHotkeyInspector.isSpotlightShortcutEnabled(systemHotkeys: systemHotkeys)
        let systemConflict = SystemHotkeyInspector.conflict(for: currentShortcut, systemHotkeys: systemHotkeys)

        let previousConflict = activeConflict
        let previousRegistered = isRegistered
        let previousSpotlight = isSpotlightShortcutEnabled

        isSpotlightShortcutEnabled = spotlightEnabled

        if let systemConflict {
            unregisterCarbon()
            activeConflict = systemConflict
            isRegistered = false
        } else if !isSuspendedForRecording {
            if !isRegistered || activeConflict != nil {
                if registerCarbon(currentShortcut) {
                    activeConflict = nil
                    isRegistered = true
                } else {
                    activeConflict = .registrationFailed
                    isRegistered = false
                }
            }
        } else {
            activeConflict = nil
        }

        if previousConflict != activeConflict
            || previousRegistered != isRegistered
            || previousSpotlight != isSpotlightShortcutEnabled {
            onStateChange?()
        }
    }

    /// Begins lightweight polling strictly while Setup or Settings is visible on screen.
    func beginLiveMonitoring() {
        liveMonitorCount += 1
        refreshSystemStatus()
        guard conflictPollTimer == nil else { return }
        conflictPollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSystemStatus()
            }
        }
    }

    /// Stops polling as soon as Setup and Settings windows are both closed (zero background polling).
    func endLiveMonitoring() {
        liveMonitorCount = max(0, liveMonitorCount - 1)
        if liveMonitorCount == 0 {
            conflictPollTimer?.invalidate()
            conflictPollTimer = nil
        }
    }

    /// Opens macOS System Settings directly to the Keyboard pane so the user can adjust Spotlight shortcuts.
    func openKeyboardSettings() {
        NSWorkspace.shared.open(SystemHotkeyInspector.keyboardSettingsURL)
    }

    @discardableResult
    private func applyShortcut(_ shortcut: HotkeyShortcut, persist: Bool) -> Bool {
        currentShortcut = shortcut
        if persist {
            preferencesStore.saveShortcut(shortcut)
        }

        let systemHotkeys = SystemHotkeyInspector.systemHotkeys()
        isSpotlightShortcutEnabled = SystemHotkeyInspector.isSpotlightShortcutEnabled(systemHotkeys: systemHotkeys)

        if let systemConflict = SystemHotkeyInspector.conflict(for: shortcut, systemHotkeys: systemHotkeys) {
            unregisterCarbon()
            activeConflict = systemConflict
            isRegistered = false
            onStateChange?()
            return false
        }

        if isSuspendedForRecording {
            activeConflict = nil
            isRegistered = false
            onStateChange?()
            return true
        }

        if registerCarbon(shortcut) {
            activeConflict = nil
            isRegistered = true
        } else {
            activeConflict = .registrationFailed
            isRegistered = false
        }
        onStateChange?()
        return isRegistered
    }

    private func registerCarbon(_ shortcut: HotkeyShortcut) -> Bool {
        unregisterCarbon()

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
            shortcut.keyCode,
            shortcut.carbonModifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            unregisterCarbon()
            return false
        }
        return true
    }

    private func unregisterCarbon() {
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
