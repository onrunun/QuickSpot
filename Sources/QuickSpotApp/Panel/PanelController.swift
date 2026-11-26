import AppKit
import Combine
import Quartz
import SwiftUI

/// Manages panel visibility, dynamic layout sizing, screen placement, delayed copy dismiss, and keyboard shortcuts.
@MainActor
final class PanelController {
    static let panelWidth: CGFloat = 780
    static let listWidth: CGFloat = 330

    let viewModel: PanelViewModel
    var onOpenSettings: (() -> Void)?
    var isSettingsVisible: (() -> Bool)?
    var window: FloatingPanelWindow?
    private var hostingView: NSHostingView<SearchBarAndListView>?
    var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var delayedHideTask: Task<Void, Never>?

    var isVisible: Bool { window?.isVisible ?? false }
    var isQuickLookVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    init(viewModel: PanelViewModel) {
        self.viewModel = viewModel
        viewModel.onRequestDelayedHide = { [weak self] delay in
            self?.scheduleHide(after: delay)
        }
        viewModel.onCancelPendingHide = { [weak self] in
            self?.cancelDelayedHide()
        }

        Publishers.MergeMany(
            viewModel.$items.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$query.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isSearchingFiles.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$toastMessage.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.resizeWindow() }
        .store(in: &cancellables)

        viewModel.$selectedIndex
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isQuickLookVisible else { return }
                self.window?.syncPreviewURL(self.viewModel.selectedItem?.previewURL)
            }
            .store(in: &cancellables)
    }

    func toggle() {
        if isVisible { hide(returnFocus: true) } else { show() }
    }

    func show() {
        cancelDelayedHide()
        let win = ensureWindow()
        viewModel.prepareForShow()
        resizeWindow()
        placeOnActiveScreen(win)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func hide(returnFocus: Bool = false) {
        cancelDelayedHide()
        let wasVisible = isVisible
        if isQuickLookVisible { QLPreviewPanel.shared().orderOut(nil) }
        removeKeyMonitor()
        if wasVisible {
            viewModel.markHidden()
        }
        if returnFocus, !(isSettingsVisible?() ?? false) {
            window?.canHide = false
            window?.orderOut(nil)
            NSApp.hide(nil)
        } else {
            window?.orderOut(nil)
        }
        PreviewImageCache.shared.clear()
    }

    private func scheduleHide(after seconds: TimeInterval) {
        delayedHideTask?.cancel()
        let delayNanos = UInt64(max(0.1, seconds) * 1_000_000_000)
        delayedHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanos)
            guard !Task.isCancelled, let self, self.isVisible else { return }
            self.hide()
        }
    }

    private func cancelDelayedHide() {
        delayedHideTask?.cancel()
        delayedHideTask = nil
    }

    private func ensureWindow() -> FloatingPanelWindow {
        if let window { return window }
        let win = FloatingPanelWindow()
        let root = SearchBarAndListView(
            viewModel: viewModel,
            onExecuteIndex: { [weak self] idx in
                guard let self else { return }
                if self.viewModel.selectAndExecute(at: idx) { self.hide() }
            },
            onReveal: { [weak self] in
                guard let self else { return }
                if self.viewModel.revealSelected() { self.hide() }
            },
            onQuickLook: { [weak self] in self?.toggleQuickLook() },
            onOpenSettings: { [weak self] in
                self?.hide()
                self?.onOpenSettings?()
            },
            onHideWithoutReturnFocus: { [weak self] in self?.hide() },
            onClose: { [weak self] in self?.hide(returnFocus: true) }
        )
        let hosting = NSHostingView(rootView: root)
        win.contentView = hosting
        self.window = win
        self.hostingView = hosting
        return win
    }

    private func placeOnActiveScreen(_ win: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = frame.midX - Self.panelWidth / 2
        let topY = frame.minY + frame.height * 0.78
        win.setFrameTopLeftPoint(NSPoint(x: x, y: topY))
    }

    private func resizeWindow() {
        guard let win = window, let hosting = hostingView else { return }
        hosting.layoutSubtreeIfNeeded()
        let targetHeight = min(max(hosting.fittingSize.height, 56), 540)
        var frame = win.frame
        guard abs(frame.height - targetHeight) >= 0.5 || abs(frame.width - Self.panelWidth) >= 0.5 else { return }
        let topY = frame.maxY
        frame.size = NSSize(width: Self.panelWidth, height: targetHeight)
        frame.origin.y = topY - targetHeight
        win.setFrame(frame, display: true)
    }

    func toggleQuickLook() {
        window?.syncPreviewURL(viewModel.selectedItem?.previewURL)
        guard let win = window, win.previewURL != nil, let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }
}
