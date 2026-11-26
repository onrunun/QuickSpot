import AppKit
import QuickSpotCore
import SwiftUI

/// Handles single-click selection, double-click open, Finder drag-out, and right-click context menus per row.
struct RowInteractionOverlay: NSViewRepresentable {
    let fileURL: URL?
    let openTitle: String
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onQuickLook: () -> Void
    let onCopy: () -> Void
    let onCopyPath: () -> Void

    func makeNSView(context: Context) -> RowInteractionNSView {
        RowInteractionNSView()
    }

    func updateNSView(_ view: RowInteractionNSView, context: Context) {
        view.fileURL = fileURL
        view.openTitle = openTitle
        view.onSelect = onSelect
        view.onOpen = onOpen
        view.onReveal = onReveal
        view.onQuickLook = onQuickLook
        view.onCopy = onCopy
        view.onCopyPath = onCopyPath
    }
}

final class RowInteractionNSView: NSView, NSDraggingSource {
    var fileURL: URL?
    var openTitle = L10n.tr("context.open")
    var onSelect: () -> Void = {}
    var onOpen: () -> Void = {}
    var onReveal: () -> Void = {}
    var onQuickLook: () -> Void = {}
    var onCopy: () -> Void = {}
    var onCopyPath: () -> Void = {}
    private var mouseDownEvent: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            mouseDownEvent = nil
            onOpen()
        } else {
            mouseDownEvent = event
            onSelect()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let url = fileURL, url.isFileURL else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy > 9 else { return }

        mouseDownEvent = nil
        let draggingItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        let point = convert(down.locationInWindow, from: nil)
        let side: CGFloat = 40
        let image = PreviewImageCache.shared.cached(url: url, side: 32)
            ?? NSWorkspace.shared.icon(forFile: url.path)
        draggingItem.setDraggingFrame(
            NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side),
            contents: image
        )
        beginDraggingSession(with: [draggingItem], event: down, source: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onSelect()
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: openTitle, action: onOpen))
        if let url = fileURL, url.isFileURL {
            menu.addItem(ClosureMenuItem(title: L10n.tr("context.reveal_in_finder"), action: onReveal))
            menu.addItem(ClosureMenuItem(title: L10n.tr("context.quick_look"), action: onQuickLook))
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: L10n.tr("context.copy"), action: onCopy))
            menu.addItem(ClosureMenuItem(title: L10n.tr("context.copy_path"), action: onCopyPath))
        } else {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: L10n.tr("context.copy"), action: onCopy))
        }
        return menu
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? .copy : .every
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.handler = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        handler()
    }
}
