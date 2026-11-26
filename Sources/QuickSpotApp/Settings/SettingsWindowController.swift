import AppKit
import QuickSpotCore
import SwiftUI

/// Lazily creates and presents the standalone native macOS Settings & Indexing window.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let viewModel: SettingsViewModel
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    func show(tab: SettingsTab? = nil) {
        if let tab {
            viewModel.selectedTab = tab
        }
        let wasVisible = isVisible
        viewModel.refreshSystemPreferences()
        let win = ensureWindow()
        win.title = L10n.tr("settings.window_title")
        if !wasVisible {
            viewModel.beginHotkeyLiveMonitoring()
        }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func refreshTitle() {
        window?.title = L10n.tr("settings.window_title")
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.endHotkeyLiveMonitoring()
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let hosting = NSHostingController(rootView: SettingsWindowView(viewModel: viewModel))
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = L10n.tr("settings.window_title")
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentViewController = hosting
        win.setContentSize(NSSize(width: 640, height: 480))
        win.center()
        self.window = win
        return win
    }
}
