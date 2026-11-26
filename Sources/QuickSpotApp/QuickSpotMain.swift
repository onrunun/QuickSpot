import AppKit
import QuickSpotCore

/// Entry point configuring QuickSpot as a zero-overhead accessory menu bar Spotlight launcher.
@main
enum QuickSpotMain {
    static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--generate-iconset" {
            let outDir = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            do {
                try BrandIcon.writeIconset(to: outDir)
                exit(0)
            } catch {
                fputs("Failed to generate iconset: \(error)\n", stderr)
                exit(1)
            }
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        if Bundle.main.bundleURL.pathExtension != "app" {
            app.applicationIconImage = BrandIcon.appIconImage(pixels: 512)
        }
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let hotkeyManager = HotkeyManager()
    var panelController: PanelController?
    var settingsController: SettingsWindowController?
    var settingsViewModel: SettingsViewModel?
    var ocrIndexer: ImageOCRIndexer?
    var clipboardHistory: ClipboardHistoryStore?
    var powerMonitor: PowerPolicyMonitor?
    var statusItem: NSStatusItem?

    var cmdSpaceItem: NSMenuItem?
    var optionSpaceItem: NSMenuItem?
    var launchAtLoginItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settingsStore = IndexSettingsStore()
        let initialSettings = settingsStore.load()
        let ocrStore = ImageOCRStore()

        let monitor = PowerPolicyMonitor(indexOnBattery: initialSettings.indexOnBattery) { [weak self] _ in
            self?.ocrIndexer?.startIndexPass(force: false)
        }
        self.powerMonitor = monitor

        let indexer = ImageOCRIndexer(
            store: ocrStore,
            settingsStore: settingsStore,
            blockerProvider: { PowerPolicyMonitor.blocker(indexOnBattery: settingsStore.load().indexOnBattery) }
        )
        self.ocrIndexer = indexer

        let clipboard = ClipboardHistoryStore()
        clipboard.startMonitoring()
        self.clipboardHistory = clipboard

        let settingsVM = SettingsViewModel(
            settingsStore: settingsStore,
            ocrIndexer: indexer,
            clipboardHistory: clipboard,
            powerMonitor: monitor,
            hotkeyManager: hotkeyManager,
            onExternalMenuSync: { [weak self] in self?.refreshMenuStates() }
        )
        self.settingsViewModel = settingsVM
        self.settingsController = SettingsWindowController(viewModel: settingsVM)

        let frecency = FrecencyStore()
        let recentFiles = RecentFilesProvider(frecency: frecency)
        recentFiles.refreshAsync()
        let viewModel = PanelViewModel(
            appScanner: AppScanner(frecency: frecency),
            frecency: frecency,
            recentFiles: recentFiles,
            spotlightSearch: SpotlightFileSearch(frecency: frecency),
            ocrIndexer: indexer,
            clipboardHistory: clipboard
        )
        viewModel.indexProgress = settingsVM.progress
        viewModel.onOpenSettings = { [weak self] in self?.settingsController?.show() }
        settingsVM.onProgressUpdate = { [weak viewModel] progress in
            viewModel?.indexProgress = progress
        }

        let controller = PanelController(viewModel: viewModel)
        controller.onOpenSettings = { [weak self] in self?.settingsController?.show() }
        controller.isSettingsVisible = { [weak self] in self?.settingsController?.isVisible ?? false }
        self.panelController = controller

        hotkeyManager.onPress = { [weak controller] in controller?.toggle() }
        hotkeyManager.register()
        NSApp.mainMenu = buildMainMenu()
        buildStatusBarMenu()

        indexer.startWatching(folders: initialSettings.folders)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak indexer] in
            indexer?.startIndexPass(force: false)
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak controller] _ in
            MainActor.assumeIsolated {
                guard let controller, !controller.isQuickLookVisible else { return }
                controller.hide()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .quickSpotLanguageDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildLocalizedMenus()
                self?.panelController?.viewModel.refreshForLanguageChange()
            }
        }
    }
}
