import AppKit
import Foundation
import QuickSpotCore

/// Describes the contextual `⌥⏎` secondary action surfaced live when holding Option.
struct AlternateActionDescriptor: Equatable {
    enum Kind: Equatable {
        case smartEntity(DetectedSmartEntity)
        case copyOCRText
        case openInTerminal(URL)
        case copyPath
        case copyItem
    }

    let title: String
    let kind: Kind
}

/// Isolates Tab path completion, Option-Return alternate actions, pasteboard copy, Finder reveal, and feedback toasts.
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
        guard let completed = PathNavigator.autocompletePath(for: item),
              completed != query else { return false }

        setQueryForAutocomplete(completed)
        return true
    }

    @discardableResult
    func stepUpDirectoryWithShiftTab() -> Bool {
        guard case .path(let rawPath) = QueryParser.parse(query).mode,
              let parent = PathNavigator.parentDirectoryQuery(for: rawPath),
              parent != query else { return false }
        setQueryForAutocomplete(parent)
        return true
    }

    /// Computes the smartest contextual secondary action (`⌥⏎`) for the currently selected result.
    var alternateAction: AlternateActionDescriptor? {
        guard let item = selectedItem, !item.requiresConfirmation else { return nil }

        if let entity = selectedSmartEntities.first(where: \.isPreviewHighlighted) {
            let title: String
            switch entity.kind {
            case .qrURL: title = L10n.tr("palette.entity.open_qr")
            case .qrText: title = L10n.tr("palette.entity.copy_qr")
            case .iban: title = L10n.tr("palette.entity.copy_iban")
            case .email: title = L10n.tr("palette.entity.copy_email")
            case .url: title = L10n.tr("palette.entity.open_url")
            }
            return AlternateActionDescriptor(title: title, kind: .smartEntity(entity))
        }

        if let text = selectedFullOCRText, !text.isEmpty {
            return AlternateActionDescriptor(title: L10n.tr("preview.action.copy_text"), kind: .copyOCRText)
        }

        if let url = item.previewURL, url.isFileURL {
            if item.category == .folder {
                return AlternateActionDescriptor(title: L10n.tr("palette.open_in_terminal"), kind: .openInTerminal(url))
            }
            return AlternateActionDescriptor(title: L10n.tr("context.copy_path"), kind: .copyPath)
        }

        if case .copyText = item.action {
            return nil
        }
        return AlternateActionDescriptor(title: L10n.tr("context.copy"), kind: .copyItem)
    }

    @discardableResult
    func executeAlternateAction() -> Bool {
        guard let descriptor = alternateAction else { return false }
        onCancelPendingHide?()
        switch descriptor.kind {
        case .smartEntity(let entity):
            return activateSmartEntity(entity)
        case .copyOCRText:
            copySelectedOCRText()
            return false
        case .openInTerminal(let url):
            if let err = FileActionService.openInTerminal(url) {
                showToast(err, style: .error, duration: 5.0)
                return false
            }
            return true
        case .copyPath:
            copySelectedPath()
            return false
        case .copyItem:
            copySelected()
            return false
        }
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

    /// Isolates the foreground subject of the selected image using Apple Vision and copies transparent PNG data to the pasteboard.
    func removeBackgroundAndCopySelected() {
        guard let url = selectedItem?.previewURL,
              url.isFileURL,
              VisionTextExtractor.isSupportedImage(url) else { return }

        backgroundRemovalTask?.cancel()
        isRemovingBackground = true
        backgroundRemovalTask = Task { [weak self] in
            let outcome: Result<Data, Error> = await Task.detached(priority: .userInitiated) {
                Result { try ImageIntelligenceService.removeBackgroundToPNG(from: url) }
            }.value
            guard !Task.isCancelled, let self else { return }
            self.isRemovingBackground = false

            switch outcome {
            case .success(let pngData):
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setData(pngData, forType: .png)
                if let image = NSImage(data: pngData), let tiff = image.tiffRepresentation {
                    pb.setData(tiff, forType: .tiff)
                }
                self.showToast(L10n.tr("panel.toast.bg_removed_copied"), style: .success, duration: 2.2)
            case .failure(let error):
                self.showToast(error.localizedDescription, style: .warning, duration: 3.2)
            }
        }
    }

    @discardableResult
    func activateSmartEntity(_ entity: DetectedSmartEntity) -> Bool {
        if let url = entity.openURL, (entity.kind == .qrURL || entity.kind == .url) {
            if NSWorkspace.shared.open(url) {
                return true
            }
        }
        copyToPasteboard(entity.copyValue)
        return false
    }

    func copySmartEntity(_ entity: DetectedSmartEntity) {
        copyToPasteboard(entity.copyValue)
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
