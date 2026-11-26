import AppKit
import QuickSpotCore
import SwiftUI

/// Lazily creates and presents the standalone macOS Settings & Indexing window.
@MainActor
final class SettingsWindowController {
    private let viewModel: SettingsViewModel
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    func show() {
        viewModel.refreshSystemPreferences()
        let win = ensureWindow()
        win.title = L10n.tr("settings.window_title")
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func refreshTitle() {
        window?.title = L10n.tr("settings.window_title")
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let hosting = NSHostingController(rootView: SettingsWindowView(viewModel: viewModel))
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = L10n.tr("settings.window_title")
        win.isReleasedWhenClosed = false
        win.contentViewController = hosting
        win.center()
        self.window = win
        return win
    }
}
