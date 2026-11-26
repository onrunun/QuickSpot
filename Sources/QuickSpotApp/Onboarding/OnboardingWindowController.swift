import AppKit
import QuickSpotCore
import ServiceManagement
import SwiftUI

/// Reactive UI state shared between `OnboardingWindowController` and `OnboardingWindowView`.
@MainActor
final class OnboardingPreferencesState: ObservableObject {
    @Published var launchAtLogin: Bool
    @Published var appLanguage: AppLanguage

    init() {
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.appLanguage = L10n.selectedLanguage
    }

    func refresh() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        appLanguage = L10n.selectedLanguage
    }
}

/// Presents the one-time Setup window and guarantees live conflict monitoring stops when closed.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let hotkeyManager: HotkeyManager
    private let prefsState = OnboardingPreferencesState()
    private let onBeforeShow: () -> Void
    private let onExternalSync: () -> Void
    private let onCompleteAndOpenPanel: () -> Void

    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    init(
        hotkeyManager: HotkeyManager,
        onBeforeShow: @escaping () -> Void = {},
        onExternalSync: @escaping () -> Void,
        onCompleteAndOpenPanel: @escaping () -> Void
    ) {
        self.hotkeyManager = hotkeyManager
        self.onBeforeShow = onBeforeShow
        self.onExternalSync = onExternalSync
        self.onCompleteAndOpenPanel = onCompleteAndOpenPanel
    }

    func show() {
        onBeforeShow()
        prefsState.refresh()
        let wasVisible = isVisible
        let win = ensureWindow()
        win.title = L10n.tr("onboarding.window_title")
        if !wasVisible {
            hotkeyManager.beginLiveMonitoring()
            win.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        win.orderFrontRegardless()
        win.makeKeyAndOrderFront(nil)
    }

    func refreshLocalization() {
        prefsState.refresh()
        window?.title = L10n.tr("onboarding.window_title")
    }

    func windowWillClose(_ notification: Notification) {
        hotkeyManager.endLiveMonitoring()
        hotkeyManager.preferencesStore.hasCompletedOnboarding = true
        // Never leave a user with a broken hotkey if they close Setup mid-conflict.
        if hotkeyManager.activeConflict != nil {
            hotkeyManager.switchToConflictFreeAlternative()
        }
        onExternalSync()
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let view = OnboardingWindowView(
            hotkeyManager: hotkeyManager,
            prefs: prefsState,
            onToggleLaunchAtLogin: { [weak self] enabled in
                self?.toggleLaunchAtLogin(enabled)
            },
            onSelectLanguage: { [weak self] language in
                self?.selectLanguage(language)
            },
            onCompleteAndOpen: { [weak self] in
                self?.finishSetup(fallbackToSafe: false)
            },
            onSwitchToSafeAndOpen: { [weak self] in
                self?.finishSetup(fallbackToSafe: true)
            }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = L10n.tr("onboarding.window_title")
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentViewController = hosting
        self.window = win
        return win
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {}
        prefsState.refresh()
        onExternalSync()
    }

    private func selectLanguage(_ language: AppLanguage) {
        L10n.setLanguage(language)
        prefsState.refresh()
        window?.title = L10n.tr("onboarding.window_title")
        onExternalSync()
    }

    private func finishSetup(fallbackToSafe: Bool) {
        if fallbackToSafe {
            hotkeyManager.switchToConflictFreeAlternative()
        } else {
            hotkeyManager.preferencesStore.saveShortcut(hotkeyManager.currentShortcut)
        }
        hotkeyManager.preferencesStore.hasCompletedOnboarding = true
        window?.close()
        onExternalSync()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.onCompleteAndOpenPanel()
        }
    }
}
