import AppKit
import Foundation
import QuickSpotCore

/// Isolates the `⌘K` secondary action palette state transitions and execution (Open With, Terminal, Trash, Clipboard).
extension PanelViewModel {
    func toggleActionPalette() {
        if isActionPaletteVisible {
            closeActionPalette()
        } else {
            openActionPalette()
        }
    }

    func openActionPalette() {
        guard let item = selectedItem else { return }
        onCancelPendingHide?()
        let actions = ActionPaletteBuilder.buildActions(
            for: item,
            fullOCRText: selectedFullOCRText,
            canFindSimilar: selectedSimilarityKind != nil,
            smartEntities: selectedSmartEntities
        )
        guard !actions.isEmpty else { return }
        setHeldModifier(.none)
        actionPaletteItems = actions
        actionPaletteIndex = 0
        actionPaletteConfirmID = nil
        isActionPaletteVisible = true
    }

    func closeActionPalette() {
        isActionPaletteVisible = false
        actionPaletteItems = []
        actionPaletteIndex = 0
        actionPaletteConfirmID = nil
    }

    func moveActionPaletteSelection(by delta: Int) {
        guard !actionPaletteItems.isEmpty else { return }
        actionPaletteIndex = (actionPaletteIndex + delta + actionPaletteItems.count) % actionPaletteItems.count
        let currentID = actionPaletteItems[actionPaletteIndex].id
        if actionPaletteConfirmID != nil && actionPaletteConfirmID != currentID {
            actionPaletteConfirmID = nil
        }
    }

    func selectActionPalette(at index: Int) {
        guard actionPaletteItems.indices.contains(index) else { return }
        actionPaletteIndex = index
        let currentID = actionPaletteItems[index].id
        if actionPaletteConfirmID != nil && actionPaletteConfirmID != currentID {
            actionPaletteConfirmID = nil
        }
    }

    func cancelActionPaletteConfirmationOrClose() {
        if actionPaletteConfirmID != nil {
            actionPaletteConfirmID = nil
        } else {
            closeActionPalette()
        }
    }

    func executeActionPalette(
        at index: Int? = nil,
        onReveal: () -> Bool,
        onQuickLook: () -> Void
    ) -> Bool {
        let targetIndex = index ?? actionPaletteIndex
        guard actionPaletteItems.indices.contains(targetIndex), let item = selectedItem else {
            closeActionPalette()
            return false
        }
        let action = actionPaletteItems[targetIndex]

        if action.isDestructive && actionPaletteConfirmID != action.id {
            actionPaletteConfirmID = action.id
            return false
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryContext = trimmed.isEmpty ? nil : trimmed

        switch action.kind {
        case .open:
            closeActionPalette()
            return executeSelected(revealInFinder: false)

        case .findSimilar:
            closeActionPalette()
            findSimilarForSelected()
            return false

        case .removeBackground:
            closeActionPalette()
            removeBackgroundAndCopySelected()
            return false

        case .enterFolder:
            closeActionPalette()
            _ = autocompleteWithTab()
            return false

        case .openWith(let appURL):
            closeActionPalette()
            guard let fileURL = item.previewURL, fileURL.isFileURL else { return false }
            frecency.record(id: fileURL.standardizedFileURL.path, query: queryContext)
            if let err = FileActionService.open(fileURL, withApplication: appURL) {
                showToast(err, style: .error, duration: 4.5)
                return false
            }
            return true

        case .revealInFinder:
            closeActionPalette()
            return onReveal()

        case .openInTerminal:
            closeActionPalette()
            guard let fileURL = item.previewURL, fileURL.isFileURL else { return false }
            if let err = FileActionService.openInTerminal(fileURL) {
                showToast(err, style: .error, duration: 5.0)
                return false
            }
            return true

        case .quickLook:
            closeActionPalette()
            onQuickLook()
            return false

        case .copyItem:
            closeActionPalette()
            copySelected()
            return false

        case .copyPath:
            closeActionPalette()
            copySelectedPath()
            return false

        case .copyOCRText:
            closeActionPalette()
            copySelectedOCRText()
            return false

        case .smartEntity(let entity):
            closeActionPalette()
            return activateSmartEntity(entity)

        case .moveToTrash:
            closeActionPalette()
            guard let fileURL = item.previewURL, fileURL.isFileURL else { return false }
            switch FileActionService.moveToTrash(fileURL) {
            case .success:
                let trashedPath = fileURL.standardizedFileURL.path
                if similarAnchor?.url?.standardizedFileURL.path == trashedPath {
                    exitSimilarMode(restorePreviousQuery: false)
                }
                recentResults.removeAll { $0.previewURL?.standardizedFileURL.path == trashedPath }
                fileResults.removeAll { $0.previewURL?.standardizedFileURL.path == trashedPath }
                ocrResults.removeAll { $0.previewURL?.standardizedFileURL.path == trashedPath }
                applyItems(items.filter { $0.previewURL?.standardizedFileURL.path != trashedPath }, preserveSelection: false)
                recentFiles.refreshAsync()
                showToast(L10n.tr("palette.toast.moved_to_trash"), style: .success)
            case .failure(let error):
                showToast(L10n.format("palette.toast.trash_failed", error.localizedDescription), style: .error, duration: 4.5)
            }
            return false

        case .deleteClipboardEntry(let entryID):
            closeActionPalette()
            clipboardHistory.delete(entryID: entryID)
            queryDidChange()
            showToast(L10n.tr("palette.toast.clipboard_deleted"), style: .success)
            return false

        case .clearClipboardHistory:
            closeActionPalette()
            clipboardHistory.clearAll()
            queryDidChange()
            showToast(L10n.tr("palette.toast.clipboard_cleared"), style: .success)
            return false
        }
    }
}
