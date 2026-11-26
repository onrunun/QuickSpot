import AppKit
import Quartz

/// Isolates local keyboard monitor, IME safety, Tab path drill-down, two-step Escape, Quick Look, and shortcuts.
extension PanelController {
    func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.ownsKeyEvent(event) else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func ownsKeyEvent(_ event: NSEvent) -> Bool {
        guard let win = window, win.isVisible else { return false }
        if event.window === win { return true }
        guard QLPreviewPanel.sharedPreviewPanelExists(), let preview = QLPreviewPanel.shared() else { return false }
        return event.window === preview && preview.dataSource === win
    }

    private static let numberKeyMap: [UInt16: Int] = [
        18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8
    ]

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        if (window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])

        if viewModel.isActionPaletteVisible {
            return handleActionPaletteKeyDown(event, mods: mods)
        }

        if mods == .command, let idx = Self.numberKeyMap[event.keyCode] {
            if viewModel.selectAndExecute(at: idx) { hide() }
            return true
        }

        switch event.keyCode {
        case 40 where mods == .command: // Cmd+K Secondary Action Palette
            viewModel.toggleActionPalette()
            return true
        case 9 where mods == [.command, .shift]: // Shift+Cmd+V Clipboard History
            viewModel.setQueryForAutocomplete("cb: ")
            return true
        case 48 where mods.isEmpty: // Tab path drill-down / completion
            _ = viewModel.autocompleteWithTab()
            return true
        case 51 where mods == .command: // Cmd+Delete clear query
            viewModel.clearQuery()
            return true
        case 126: // Up
            viewModel.moveSelection(by: -1)
            return true
        case 125: // Down
            viewModel.moveSelection(by: 1)
            return true
        case 36, 76: // Return / Keypad Enter
            if viewModel.executeSelected(revealInFinder: mods.contains(.command)) { hide() }
            return true
        case 53: // Two-step Escape
            if isQuickLookVisible {
                QLPreviewPanel.shared().orderOut(nil)
                return true
            }
            if viewModel.pendingConfirmationID != nil {
                viewModel.cancelConfirmation()
                return true
            }
            if !viewModel.query.isEmpty {
                viewModel.clearQuery()
                return true
            }
            if viewModel.cancelOrDismiss() {
                hide(returnFocus: true)
            }
            return true
        case 49 where mods.isEmpty
            && (viewModel.hasNavigated || isQuickLookVisible)
            && viewModel.selectedItem?.previewURL != nil: // Space Quick Look
            toggleQuickLook()
            return true
        case 0 where mods == .command: // Cmd+A Select All
            viewModel.hasNavigated = false
            return false
        case 8 where mods == [.command, .option]: // Opt+Cmd+C Copy Path
            viewModel.copySelectedPath()
            return true
        case 8 where mods == .command: // Cmd+C
            if let tv = window?.firstResponder as? NSTextView,
               tv.selectedRange().length > 0,
               (!tv.isFieldEditor || !viewModel.hasNavigated) {
                return false
            }
            viewModel.copySelected()
            return true
        case 16 where mods == .command: // Cmd+Y Quick Look
            toggleQuickLook()
            return true
        case 43 where mods == .command: // Cmd+, Settings
            hide()
            onOpenSettings?()
            return true
        default:
            return false
        }
    }

    private func handleActionPaletteKeyDown(_ event: NSEvent, mods: NSEvent.ModifierFlags) -> Bool {
        switch event.keyCode {
        case 126: // Up
            viewModel.moveActionPaletteSelection(by: -1)
            return true
        case 125: // Down
            viewModel.moveActionPaletteSelection(by: 1)
            return true
        case 36, 76: // Return / Keypad Enter
            let shouldHide = viewModel.executeActionPalette(
                onReveal: { [weak self] in self?.viewModel.revealSelected() ?? false },
                onQuickLook: { [weak self] in self?.toggleQuickLook() }
            )
            if shouldHide { hide() }
            return true
        case 53: // Escape
            viewModel.cancelActionPaletteConfirmationOrClose()
            return true
        case 40 where mods == .command: // Cmd+K toggle close
            viewModel.closeActionPalette()
            return true
        default:
            return true
        }
    }
}
