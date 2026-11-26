import AppKit
import QuickSpotCore
import ServiceManagement
import SwiftUI

/// Isolates main application menu (`⌘A`/`⌘C`/`⌘V`/`⌘Z`) and native macOS status bar menu construction.
extension AppDelegate {
    func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: L10n.tr("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.tr("menu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L10n.tr("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenu = NSMenu(title: L10n.tr("menu.file"))
        fileMenu.addItem(withTitle: L10n.tr("menu.close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenu = NSMenu(title: L10n.tr("menu.edit"))
        editMenu.addItem(withTitle: L10n.tr("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L10n.tr("menu.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.tr("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.tr("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.tr("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.tr("menu.select_all"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenu(title: L10n.tr("menu.window"))
        windowMenu.addItem(withTitle: L10n.tr("menu.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu

        for submenu in [appMenu, fileMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }

    func buildStatusBarMenu() {
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        isMenuBarIndexingIndicatorActive = isCurrentlyIndexing()
        item.button?.image = BrandIcon.menuBarImage(isIndexing: isMenuBarIndexingIndicatorActive)
        item.button?.toolTip = menuBarToolTip()

        let menu = NSMenu()
        menu.autoenablesItems = false

        // Live SwiftUI indexing summary & metrics header card.
        if let vm = settingsViewModel {
            let headerItem = NSMenuItem()
            let headerView = MenuBarStatusHeaderView(viewModel: vm) { [weak self, weak menu] in
                menu?.cancelTracking()
                self?.openIndexingSettings()
            }
            let hosting = NSHostingView(rootView: headerView)
            hosting.frame = NSRect(x: 0, y: 0, width: 276, height: 92)
            headerItem.view = hosting
            menu.addItem(headerItem)
            self.indexingStatusMenuItem = headerItem
            menu.addItem(.separator())
        }

        if hotkeyManager.activeConflict != nil {
            let conflictTitle = L10n.format("menu.hotkey_conflict", hotkeyManager.currentShortcut.displayString)
            let conflictItem = makeMenuItem(
                title: conflictTitle,
                symbol: "exclamationmark.triangle.fill",
                action: #selector(openSetupGuide),
                tint: .systemOrange
            )
            menu.addItem(conflictItem)
            menu.addItem(.separator())
        }

        let openTitle = hotkeyManager.activeConflict == nil
            ? "\(L10n.tr("menu.open_quickspot")) (\(hotkeyManager.currentShortcut.displayString))"
            : L10n.tr("menu.open_quickspot")
        menu.addItem(makeMenuItem(title: openTitle, symbol: "magnifyingglass", action: #selector(openPanel)))

        let indexNowItem = makeMenuItem(
            title: L10n.tr("settings.ocr.index_now"),
            symbol: "arrow.triangle.2.circlepath",
            action: #selector(triggerIndexNowFromMenu)
        )
        indexNowItem.isHidden = !shouldShowIndexNowInMenu()
        menu.addItem(indexNowItem)
        self.indexNowMenuItem = indexNowItem

        menu.addItem(.separator())

        menu.addItem(makeMenuItem(
            title: L10n.tr("menu.settings"),
            symbol: "gearshape",
            action: #selector(openSettings),
            keyEquivalent: ","
        ))
        menu.addItem(makeMenuItem(
            title: L10n.tr("menu.setup_guide"),
            symbol: "command",
            action: #selector(openSetupGuide)
        ))

        menu.addItem(.separator())

        let hotkeyHeader = makeMenuItem(
            title: L10n.tr("menu.global_hotkey"),
            symbol: "keyboard",
            action: nil
        )
        hotkeyHeader.submenu = buildHotkeySubmenu()
        menu.addItem(hotkeyHeader)

        let loginItem = makeMenuItem(
            title: L10n.tr("menu.launch_at_login"),
            symbol: "sunrise",
            action: #selector(toggleLaunchAtLogin)
        )
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        menu.addItem(makeMenuItem(
            title: L10n.tr("menu.quit"),
            symbol: "power",
            action: #selector(quitApp),
            keyEquivalent: "q"
        ))

        item.menu = menu
        self.statusItem = item
    }

    private func makeMenuItem(
        title: String,
        symbol: String,
        action: Selector?,
        keyEquivalent: String = "",
        tint: NSColor? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = action == nil ? nil : self
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(config) {
            if let tint {
                let tinted = base.withSymbolConfiguration(.init(hierarchicalColor: tint))
                item.image = tinted ?? base
            } else {
                item.image = base
            }
        }
        return item
    }

    /// Updates menu bar indicator dot, hover tooltip, and action visibility in-place (header view observes ViewModel directly).
    func updateMenuBarIndexingStatus() {
        let active = isCurrentlyIndexing()
        if active != isMenuBarIndexingIndicatorActive {
            isMenuBarIndexingIndicatorActive = active
            statusItem?.button?.image = BrandIcon.menuBarImage(isIndexing: active)
        }
        statusItem?.button?.toolTip = menuBarToolTip()
        indexNowMenuItem?.isHidden = !shouldShowIndexNowInMenu()
    }

    private func isCurrentlyIndexing() -> Bool {
        if let ocrState = settingsViewModel?.progress.state {
            switch ocrState {
            case .scanning, .indexing: return true
            case .idle, .paused: break
            }
        }
        if let semState = settingsViewModel?.semanticProgress.state {
            switch semState {
            case .scanning, .indexing: return true
            case .idle, .paused, .modelsMissing: break
            }
        }
        return false
    }

    private func shouldShowIndexNowInMenu() -> Bool {
        guard let vm = settingsViewModel else { return false }
        guard vm.settings.isOCREnabled || vm.semanticSettings.isEnabled else { return false }
        return !isCurrentlyIndexing()
    }

    private func menuBarToolTip() -> String {
        let base = "QuickSpot (\(hotkeyManager.currentShortcut.displayString))"
        guard let vm = settingsViewModel else { return base }
        if case .indexing(let done, let total) = vm.progress.state {
            return "\(base) — \(L10n.format("menu.indexing.ocr_progress", done, total))"
        }
        if case .indexing(let done, let total) = vm.semanticProgress.state {
            return "\(base) — \(L10n.format("menu.indexing.semantic_progress", done, total))"
        }
        if isCurrentlyIndexing() {
            return "\(base) — \(L10n.tr("menu.indexing.scanning"))"
        }
        return base
    }

    private func buildHotkeySubmenu() -> NSMenu {
        let hotkeyMenu = NSMenu()
        let current = hotkeyManager.currentShortcut

        let optItem = NSMenuItem(title: HotkeyPreset.optionSpace.title, action: #selector(selectOptionSpace), keyEquivalent: "")
        optItem.target = self
        optItem.state = current == .optionSpace ? .on : .off
        hotkeyMenu.addItem(optItem)

        let cmdItem = NSMenuItem(title: HotkeyPreset.cmdSpace.title, action: #selector(selectCmdSpace), keyEquivalent: "")
        cmdItem.target = self
        cmdItem.state = current == .cmdSpace ? .on : .off
        hotkeyMenu.addItem(cmdItem)

        let optCmdItem = NSMenuItem(title: HotkeyPreset.optionCmdSpace.title, action: #selector(selectOptionCmdSpace), keyEquivalent: "")
        optCmdItem.target = self
        optCmdItem.state = current == .optionCmdSpace ? .on : .off
        hotkeyMenu.addItem(optCmdItem)

        if current.matchingPreset == nil {
            let customItem = NSMenuItem(
                title: L10n.format("menu.custom_hotkey_active", current.displayString),
                action: #selector(openGeneralSettings),
                keyEquivalent: ""
            )
            customItem.target = self
            customItem.state = .on
            hotkeyMenu.addItem(customItem)
        }

        hotkeyMenu.addItem(.separator())
        let customAction = NSMenuItem(title: L10n.tr("menu.custom_hotkey"), action: #selector(openGeneralSettings), keyEquivalent: "")
        customAction.target = self
        hotkeyMenu.addItem(customAction)
        return hotkeyMenu
    }

    func rebuildLocalizedMenus() {
        NSApp.mainMenu = buildMainMenu()
        buildStatusBarMenu()
        settingsController?.refreshTitle()
        onboardingController?.refreshLocalization()
    }

    func refreshMenuStates() {
        buildStatusBarMenu()
    }

    @objc func openPanel() { panelController?.show() }

    @objc func openSettings() { settingsController?.show() }

    @objc func openIndexingSettings() { settingsController?.show(tab: .indexing) }

    @objc func openGeneralSettings() { settingsController?.show(tab: .general) }

    @objc func openSetupGuide() { onboardingController?.show() }

    @objc func triggerIndexNowFromMenu() {
        indexingCoordinator?.startPass(force: true)
    }

    @objc func selectCmdSpace() { selectMenuPreset(.cmdSpace) }

    @objc func selectOptionSpace() { selectMenuPreset(.optionSpace) }

    @objc func selectOptionCmdSpace() { selectMenuPreset(.optionCmdSpace) }

    private func selectMenuPreset(_ preset: HotkeyPreset) {
        let succeeded = hotkeyManager.selectPreset(preset)
        refreshMenuStates()
        settingsViewModel?.refreshSystemPreferences()
        if !succeeded, hotkeyManager.activeConflict != nil {
            onboardingController?.show()
        }
    }

    @objc func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {}
        refreshMenuStates()
        settingsViewModel?.refreshSystemPreferences()
    }

    @objc func quitApp() { NSApp.terminate(nil) }
}
