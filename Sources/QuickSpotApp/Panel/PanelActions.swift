import AppKit
import Foundation
import QuickSpotCore

/// Isolates Tab path completion, pasteboard copy actions, Finder reveal, and unified feedback toasts.
extension PanelViewModel {
    @discardableResult
    func autocompleteWithTab() -> Bool {
        guard let item = selectedItem else { return false }
        let isPathMode: Bool
        if case .path = QueryParser.parse(query).mode {
            isPathMode = true
        } else {
            isPathMode = false
        }

        guard item.category == .folder || isPathMode else { return false }
        guard let completed = PathNavigator.autocompletePath(for: item) else { return false }

        setQueryForAutocomplete(completed)
        return true
    }

    func copySelected() {
        guard let item = selectedItem else { return }
        switch item.action {
        case .copyText(let text):
            copyToPasteboard(text)
        case .openFile(let url):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
            showToast(L10n.tr("panel.toast.copied"), style: .success)
        case .openURL(let url):
            copyToPasteboard(url.absoluteString)
        case .runTerminal(let cmd):
            copyToPasteboard(cmd)
        case .systemCommand, .openSettings:
            copyToPasteboard(item.title)
        }
    }

    func copySelectedOCRText() {
        if let text = selectedFullOCRText, !text.isEmpty {
            copyToPasteboard(text)
            return
        }
        guard let url = selectedItem?.previewURL, url.isFileURL, let ocrIndexer else { return }
        let path = url.standardizedFileURL.path
        Task { [weak self] in
            guard let text = await ocrIndexer.fullTextAsync(forPath: path), !text.isEmpty else { return }
            self?.copyToPasteboard(text)
        }
    }

    func revealSelected() -> Bool {
        guard let item = selectedItem else { return false }
        if let url = item.previewURL, url.isFileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return true
        }
        if case .openURL(let url) = item.action {
            copyToPasteboard(url.absoluteString)
        }
        return false
    }

    func copySelectedPath() {
        if let url = selectedItem?.previewURL {
            copyToPasteboard(url.path)
        } else {
            copySelected()
        }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        clipboardHistory.promoteCopiedText(text)
        showToast(L10n.tr("panel.toast.copied"), style: .success)
    }

    func showToast(_ message: String, style: ToastStyle, duration: TimeInterval = 1.6) {
        toastMessage = message
        toastStyle = style
        toastTask?.cancel()
        let delayNanos = UInt64(max(0.2, duration) * 1_000_000_000)
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanos)
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }

    func clearToast() {
        toastTask?.cancel()
        toastTask = nil
        toastMessage = nil
    }
}
