import AppKit
import QuickSpotCore
import SwiftUI

/// Lazily creates and presents the standalone Near-Duplicate Photo Finder & Cleaner window.
@MainActor
final class DuplicateFinderWindowController: NSObject {
    private let viewModel: DuplicateFinderViewModel
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    init(semanticIndexer: SemanticImageIndexer) {
        self.viewModel = DuplicateFinderViewModel(semanticIndexer: semanticIndexer)
    }

    func show() {
        let win = ensureWindow()
        win.title = L10n.tr("duplicates.window_title")
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        viewModel.scan()
    }

    func refreshTitle() {
        window?.title = L10n.tr("duplicates.window_title")
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let hosting = NSHostingController(rootView: DuplicateFinderWindowView(viewModel: viewModel))
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = L10n.tr("duplicates.window_title")
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 680, height: 460)
        win.contentViewController = hosting
        win.setContentSize(NSSize(width: 740, height: 520))
        win.center()
        self.window = win
        return win
    }
}
