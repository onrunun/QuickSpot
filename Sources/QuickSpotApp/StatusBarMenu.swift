import AppKit
import QuickSpotCore
import ServiceManagement

/// Isolates main application menu (`⌘A`/`⌘C`/`⌘V`/`⌘Z`) and status bar menu construction.
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
        item.button?.image = BrandIcon.menuBarImage()
        item.button?.toolTip = "QuickSpot"

        let menu = NSMenu()
        let openItem = NSMenuItem(title: L10n.tr("menu.open_quickspot"), action: #selector(openPanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(title: L10n.tr("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let hotkeyHeader = NSMenuItem(title: L10n.tr("menu.global_hotkey"), action: nil, keyEquivalent: "")
        let hotkeyMenu = NSMenu()
        let cmdItem = NSMenuItem(title: HotkeyPreset.cmdSpace.title, action: #selector(selectCmdSpace), keyEquivalent: "")
        cmdItem.target = self
        let optItem = NSMenuItem(title: HotkeyPreset.optionSpace.title, action: #selector(selectOptionSpace), keyEquivalent: "")
        optItem.target = self
        hotkeyMenu.addItem(cmdItem)
        hotkeyMenu.addItem(optItem)
        hotkeyHeader.submenu = hotkeyMenu
        menu.addItem(hotkeyHeader)

        let loginItem = NSMenuItem(title: L10n.tr("menu.launch_at_login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: L10n.tr("menu.quit"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.cmdSpaceItem = cmdItem
        self.optionSpaceItem = optItem
        self.launchAtLoginItem = loginItem
        refreshMenuStates()

        item.menu = menu
        self.statusItem = item
    }

    func rebuildLocalizedMenus() {
        NSApp.mainMenu = buildMainMenu()
        buildStatusBarMenu()
        settingsController?.refreshTitle()
    }

    func refreshMenuStates() {
        cmdSpaceItem?.state = hotkeyManager.currentPreset == .cmdSpace ? .on : .off
        optionSpaceItem?.state = hotkeyManager.currentPreset == .optionSpace ? .on : .off
        launchAtLoginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func openPanel() { panelController?.show() }

    @objc func openSettings() { settingsController?.show() }

    @objc func selectCmdSpace() {
        hotkeyManager.register(preset: .cmdSpace)
        refreshMenuStates()
        settingsViewModel?.refreshSystemPreferences()
    }

    @objc func selectOptionSpace() {
        hotkeyManager.register(preset: .optionSpace)
        refreshMenuStates()
        settingsViewModel?.refreshSystemPreferences()
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
