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
    var duplicateFinderController: DuplicateFinderWindowController?
    var onboardingController: OnboardingWindowController?
    var settingsViewModel: SettingsViewModel?
    var ocrIndexer: ImageOCRIndexer?
    var semanticIndexer: SemanticImageIndexer?
    var indexingCoordinator: IndexingCoordinator?
    var clipboardHistory: ClipboardHistoryStore?
    var powerMonitor: PowerPolicyMonitor?
    var statusItem: NSStatusItem?
    var indexingStatusMenuItem: NSMenuItem?
    var indexNowMenuItem: NSMenuItem?
    var isMenuBarIndexingIndicatorActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settingsStore = IndexSettingsStore()
        let initialSettings = settingsStore.load()
        let ocrStore = ImageOCRStore()
        let semanticSettingsStore = SemanticSettingsStore()
        let semanticStore = SemanticVectorStore()

        let monitor = PowerPolicyMonitor(indexOnBattery: initialSettings.indexOnBattery) { [weak self] blocker in
            self?.indexingCoordinator?.handlePowerPolicyChange(blocker: blocker)
        }
        self.powerMonitor = monitor

        let blocker: @Sendable () -> String? = {
            PowerPolicyMonitor.blocker(indexOnBattery: settingsStore.load().indexOnBattery)
        }
        let interactiveState = InteractiveSearchFlag()
        let pacer = IndexingPacer.live(
            settingsStore: settingsStore,
            isInteractiveSearchActive: { interactiveState.isActive }
        )
        let indexer = ImageOCRIndexer(
            store: ocrStore,
            settingsStore: settingsStore,
            blockerProvider: blocker,
            pacer: pacer
        )
        self.ocrIndexer = indexer

        let semanticEngine = SemanticEmbeddingEngine(settingsStore: semanticSettingsStore)
        let semanticDocIndexer = SemanticDocumentIndexer(
            ocrStore: ocrStore,
            engine: semanticEngine,
            pacer: pacer
        )
        let semIndexer = SemanticImageIndexer(
            store: semanticStore,
            documentIndexer: semanticDocIndexer,
            engine: semanticEngine,
            folderSettingsStore: settingsStore,
            semanticSettingsStore: semanticSettingsStore,
            blockerProvider: blocker,
            pacer: pacer
        )
        self.semanticIndexer = semIndexer

        let coordinator = IndexingCoordinator(
            ocrIndexer: indexer,
            semanticIndexer: semIndexer,
            folderSettingsStore: settingsStore,
            semanticSettingsStore: semanticSettingsStore,
            blockerProvider: blocker,
            pacer: pacer
        )
        self.indexingCoordinator = coordinator

        let clipboard = ClipboardHistoryStore()
        clipboard.startMonitoring()
        self.clipboardHistory = clipboard

        let settingsVM = SettingsViewModel(
            settingsStore: settingsStore,
            ocrIndexer: indexer,
            semanticSettingsStore: semanticSettingsStore,
            semanticIndexer: semIndexer,
            indexingCoordinator: coordinator,
            clipboardHistory: clipboard,
            powerMonitor: monitor,
            hotkeyManager: hotkeyManager,
            onExternalMenuSync: { [weak self] in self?.refreshMenuStates() }
        )
        let duplicateController = DuplicateFinderWindowController(semanticIndexer: semIndexer)
        self.duplicateFinderController = duplicateController

        settingsVM.onOpenSetupGuide = { [weak self] in self?.onboardingController?.show() }
        settingsVM.onOpenDuplicateFinder = { [weak self] in self?.duplicateFinderController?.show() }
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
            semanticIndexer: semIndexer,
            clipboardHistory: clipboard
        )
        viewModel.indexProgress = settingsVM.progress
        viewModel.semanticProgress = settingsVM.semanticProgress
        viewModel.onOpenSettings = { [weak self] in self?.settingsController?.show() }
        viewModel.onOpenDuplicateFinder = { [weak self] in self?.duplicateFinderController?.show() }
        settingsVM.onProgressUpdate = { [weak self, weak viewModel] progress in
            viewModel?.indexProgress = progress
            self?.updateMenuBarIndexingStatus()
        }
        settingsVM.onSemanticProgressUpdate = { [weak self, weak viewModel] progress in
            viewModel?.semanticProgress = progress
            self?.updateMenuBarIndexingStatus()
        }

        let controller = PanelController(viewModel: viewModel)
        controller.onOpenSettings = { [weak self] in self?.settingsController?.show() }
        controller.isSettingsVisible = { [weak self] in
            (self?.settingsController?.isVisible ?? false)
                || (self?.onboardingController?.isVisible ?? false)
                || (self?.duplicateFinderController?.isVisible ?? false)
        }
        controller.onVisibilityChanged = { visible in
            interactiveState.setActive(visible)
        }
        self.panelController = controller

        let onboarding = OnboardingWindowController(
            hotkeyManager: hotkeyManager,
            onBeforeShow: { [weak controller] in
                controller?.hide()
            },
            onExternalSync: { [weak self] in
                self?.refreshMenuStates()
                self?.settingsViewModel?.refreshSystemPreferences()
            },
            onCompleteAndOpenPanel: { [weak controller] in
                controller?.show()
            }
        )
        self.onboardingController = onboarding

        hotkeyManager.onPress = { [weak controller] in controller?.toggle() }
        hotkeyManager.onStateChange = { [weak self] in
            self?.refreshMenuStates()
            self?.settingsViewModel?.refreshSystemPreferences()
        }
        hotkeyManager.registerInitial()

        NSApp.mainMenu = buildMainMenu()
        buildStatusBarMenu()

        coordinator.startWatching()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak coordinator] in
            coordinator?.startPass(force: false)
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
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hotkeyManager.refreshSystemStatus()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .quickSpotLanguageDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildLocalizedMenus()
                self?.duplicateFinderController?.refreshTitle()
                self?.panelController?.viewModel.refreshForLanguageChange()
            }
        }

        let forceSetup = CommandLine.arguments.contains("--show-setup")
        if forceSetup || !hotkeyManager.preferencesStore.hasCompletedOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak onboarding] in
                onboarding?.show()
            }
        }
    }
}

/// Lock-guarded boolean signaling active launcher panel visibility to background indexing threads.
private final class InteractiveSearchFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false

    var isActive: Bool {
        lock.withLock { active }
    }

    func setActive(_ value: Bool) {
        lock.withLock { active = value }
    }
}
