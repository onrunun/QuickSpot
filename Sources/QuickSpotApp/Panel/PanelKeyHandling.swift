import AppKit
import Quartz

/// Isolates local keyboard & modifier monitoring, IME safety, Tab drill-in/palette, Option-Return, section jump, and Quick Look.
extension PanelController {
    func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.ownsKeyEvent(event) else { return event }
            if event.type == .flagsChanged {
                self.handleFlagsChanged(event)
                return event
            }
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

    private func cleanModifiers(from event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard !viewModel.isActionPaletteVisible else {
            viewModel.setHeldModifier(.none)
            return
        }
        let mods = cleanModifiers(from: event)
        if mods == .command {
            viewModel.setHeldModifier(.command)
        } else if mods == .option {
            viewModel.setHeldModifier(.option)
        } else {
            viewModel.setHeldModifier(.none)
        }
    }

    private func homeRowNavigationDelta(for event: NSEvent, mods: NSEvent.ModifierFlags) -> Int? {
        guard mods == .control,
              let ch = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        switch ch {
        case "n", "j": return 1
        case "p", "k": return -1
        default: return nil
        }
    }

    private func isCaretAtEndOfSearchField() -> Bool {
        if viewModel.query.isEmpty { return true }
        guard let tv = window?.firstResponder as? NSTextView else { return true }
        let sel = tv.selectedRange()
        let utf16Count = (tv.string as NSString).length
        return sel.length == 0 && sel.location >= utf16Count
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        if (window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
        let mods = cleanModifiers(from: event)

        if viewModel.isActionPaletteVisible {
            return handleActionPaletteKeyDown(event, mods: mods)
        }

        if let delta = homeRowNavigationDelta(for: event, mods: mods) {
            viewModel.moveSelection(by: delta)
            return true
        }

        if mods == .command, let idx = Self.numberKeyMap[event.keyCode] {
            viewModel.setHeldModifier(.none)
            if viewModel.selectAndExecute(at: idx) { hide() }
            return true
        }

        switch event.keyCode {
        case 40 where mods == .command: // Cmd+K Secondary Action Palette
            viewModel.toggleActionPalette()
            return true
        case 1 where mods == [.command, .shift]: // Shift+Cmd+S Find Similar
            viewModel.findSimilarForSelected()
            return true
        case 34 where mods == [.command, .shift]: // Shift+Cmd+I Find Similar to Clipboard Image
            viewModel.findSimilarFromClipboardImage()
            return true
        case 9 where mods == [.command, .shift]: // Shift+Cmd+V Clipboard History
            viewModel.setQueryForAutocomplete("cb: ")
            return true
        case 48 where mods.isEmpty: // Tab: folder/path drill-in, else open Action Palette
            if !viewModel.autocompleteWithTab() {
                viewModel.openActionPalette()
            }
            return true
        case 48 where mods == .shift: // Shift+Tab: step up one directory in path mode
            _ = viewModel.stepUpDirectoryWithShiftTab()
            return true
        case 51 where mods == .command: // Cmd+Delete clear query and similar mode
            viewModel.clearQueryAndSimilar()
            return true
        case 51 where mods.isEmpty && viewModel.query.isEmpty && viewModel.similarAnchor != nil: // Delete chip
            viewModel.exitSimilarMode()
            return true
        case 126 where mods == .command: // Cmd+Up jump to previous section
            viewModel.moveSelectionBySection(direction: -1)
            return true
        case 125 where mods == .command: // Cmd+Down jump to next section
            viewModel.moveSelectionBySection(direction: 1)
            return true
        case 126: // Up
            viewModel.moveSelection(by: -1)
            return true
        case 125: // Down
            viewModel.moveSelection(by: 1)
            return true
        case 124 where mods.isEmpty && !isQuickLookVisible && isCaretAtEndOfSearchField(): // Right at end: drill-in / Action Palette
            if !viewModel.autocompleteWithTab() {
                viewModel.openActionPalette()
            }
            return true
        case 123 where mods.isEmpty && !isQuickLookVisible && viewModel.query.isEmpty && viewModel.similarAnchor != nil: // Left on empty Similar mode: exit
            viewModel.exitSimilarMode()
            return true
        case 36 where mods == .option, 76 where mods == .option: // Option+Return smart contextual alternate action
            viewModel.setHeldModifier(.none)
            if viewModel.executeAlternateAction() { hide() }
            return true
        case 36, 76: // Return / Cmd+Return
            viewModel.setHeldModifier(.none)
            if viewModel.executeSelected(revealInFinder: mods.contains(.command)) { hide() }
            return true
        case 53: // Multi-step Escape
            viewModel.setHeldModifier(.none)
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
            if viewModel.similarAnchor != nil {
                viewModel.exitSimilarMode()
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
        if let delta = homeRowNavigationDelta(for: event, mods: mods) {
            viewModel.moveActionPaletteSelection(by: delta)
            return true
        }
        switch event.keyCode {
        case 126: // Up
            viewModel.moveActionPaletteSelection(by: -1)
            return true
        case 125: // Down
            viewModel.moveActionPaletteSelection(by: 1)
            return true
        case 48 where mods.isEmpty: // Tab next action
            viewModel.moveActionPaletteSelection(by: 1)
            return true
        case 48 where mods == .shift: // Shift+Tab previous action
            viewModel.moveActionPaletteSelection(by: -1)
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
        case 123 where mods.isEmpty: // Left arrow closes Action Palette
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
