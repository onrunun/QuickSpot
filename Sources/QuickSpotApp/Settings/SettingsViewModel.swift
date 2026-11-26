import AppKit
import QuickSpotCore
import ServiceManagement
import SwiftUI

/// Top-level navigation sections in the QuickSpot Settings window.
enum SettingsTab: String, CaseIterable, Identifiable {
    case indexing
    case folders
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .indexing: return L10n.tr("settings.tab.indexing")
        case .folders: return L10n.tr("settings.tab.folders")
        case .general: return L10n.tr("settings.tab.general")
        }
    }

    var symbol: String {
        switch self {
        case .indexing: return "sparkles"
        case .folders: return "folder.fill"
        case .general: return "gearshape.fill"
        }
    }

    var badgeTint: Color {
        switch self {
        case .indexing: return .purple
        case .folders: return .blue
        case .general: return .gray
        }
    }
}

/// Drives the Settings & Indexing UI, syncing OCR folder preferences, power rules, hotkey, and login state.
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var selectedTab: SettingsTab = .indexing
    @Published var settings: IndexSettings
    @Published var progress: IndexProgress
    @Published var semanticSettings: SemanticSettings
    @Published var semanticProgress: SemanticIndexProgress
    @Published var hotkeyShortcut: HotkeyShortcut
    @Published var hotkeyConflict: HotkeyConflict?
    @Published var isSpotlightShortcutEnabled: Bool
    @Published var launchAtLogin: Bool
    @Published var appLanguage: AppLanguage
    @Published var clipboardEnabled: Bool
    @Published var clipboardCount: Int

    private let settingsStore: IndexSettingsStore
    private let ocrIndexer: ImageOCRIndexer
    private let semanticSettingsStore: SemanticSettingsStore
    private let semanticIndexer: SemanticImageIndexer
    private let indexingCoordinator: IndexingCoordinator
    private let clipboardHistory: ClipboardHistoryStore
    private let powerMonitor: PowerPolicyMonitor
    private let hotkeyManager: HotkeyManager
    private let onExternalMenuSync: () -> Void
    var onProgressUpdate: ((IndexProgress) -> Void)?
    var onSemanticProgressUpdate: ((SemanticIndexProgress) -> Void)?
    var onOpenSetupGuide: (() -> Void)?
    var onOpenDuplicateFinder: (() -> Void)?

    init(
        settingsStore: IndexSettingsStore,
        ocrIndexer: ImageOCRIndexer,
        semanticSettingsStore: SemanticSettingsStore = SemanticSettingsStore(),
        semanticIndexer: SemanticImageIndexer = SemanticImageIndexer(),
        indexingCoordinator: IndexingCoordinator? = nil,
        clipboardHistory: ClipboardHistoryStore = ClipboardHistoryStore(),
        powerMonitor: PowerPolicyMonitor,
        hotkeyManager: HotkeyManager,
        onExternalMenuSync: @escaping () -> Void
    ) {
        self.settingsStore = settingsStore
        self.ocrIndexer = ocrIndexer
        self.semanticSettingsStore = semanticSettingsStore
        self.semanticIndexer = semanticIndexer
        self.indexingCoordinator = indexingCoordinator ?? IndexingCoordinator(
            ocrIndexer: ocrIndexer,
            semanticIndexer: semanticIndexer,
            folderSettingsStore: settingsStore,
            semanticSettingsStore: semanticSettingsStore
        )
        self.clipboardHistory = clipboardHistory
        self.powerMonitor = powerMonitor
        self.hotkeyManager = hotkeyManager
        self.onExternalMenuSync = onExternalMenuSync
        let loaded = settingsStore.load()
        self.settings = loaded
        let initialState: IndexProgress.State = loaded.isOCREnabled
            ? (powerMonitor.blocker.map { .paused(reason: $0) } ?? .idle)
            : .idle
        self.progress = ocrIndexer.currentSnapshot(state: initialState)

        let loadedSemantic = semanticSettingsStore.load()
        self.semanticSettings = loadedSemantic
        let initialSemanticState: SemanticIndexProgress.State? = loadedSemantic.isEnabled
            ? (powerMonitor.blocker.map { .paused(reason: $0) })
            : .idle
        self.semanticProgress = semanticIndexer.currentSnapshot(state: initialSemanticState)

        self.hotkeyShortcut = hotkeyManager.currentShortcut
        self.hotkeyConflict = hotkeyManager.activeConflict
        self.isSpotlightShortcutEnabled = hotkeyManager.isSpotlightShortcutEnabled
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.appLanguage = L10n.selectedLanguage
        self.clipboardEnabled = clipboardHistory.isEnabled
        self.clipboardCount = clipboardHistory.count

        ocrIndexer.setProgressHandler { [weak self] updated in
            Task { @MainActor [weak self] in
                self?.progress = updated
                self?.onProgressUpdate?(updated)
            }
        }
        semanticIndexer.setProgressHandler { [weak self] updated in
            Task { @MainActor [weak self] in
                self?.semanticProgress = updated
                self?.onSemanticProgressUpdate?(updated)
            }
        }
    }

    func refreshSystemPreferences() {
        hotkeyShortcut = hotkeyManager.currentShortcut
        hotkeyConflict = hotkeyManager.activeConflict
        isSpotlightShortcutEnabled = hotkeyManager.isSpotlightShortcutEnabled
        launchAtLogin = SMAppService.mainApp.status == .enabled
        appLanguage = L10n.selectedLanguage
        clipboardEnabled = clipboardHistory.isEnabled
        clipboardCount = clipboardHistory.count
    }

    func toggleClipboardEnabled(_ enabled: Bool) {
        clipboardHistory.isEnabled = enabled
        clipboardEnabled = enabled
        clipboardCount = clipboardHistory.count
    }

    func clearClipboardHistory() {
        clipboardHistory.clearAll()
        clipboardCount = clipboardHistory.count
    }

    func openDuplicateFinder() {
        onOpenDuplicateFinder?()
    }

    func selectLanguage(_ language: AppLanguage) {
        L10n.setLanguage(language)
        appLanguage = language
        if let refreshedReason = PowerPolicyMonitor.blocker(indexOnBattery: settings.indexOnBattery) {
            if settings.isOCREnabled, case .paused = progress.state {
                progress = ocrIndexer.currentSnapshot(state: .paused(reason: refreshedReason))
                onProgressUpdate?(progress)
            }
            if semanticSettings.isEnabled, case .paused = semanticProgress.state {
                semanticProgress = semanticIndexer.currentSnapshot(state: .paused(reason: refreshedReason))
                onSemanticProgressUpdate?(semanticProgress)
            }
        }
        onExternalMenuSync()
    }

    func addFolderViaPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.tr("settings.folders.add_prompt")
        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            settings = settingsStore.addFolder(url.path)
        }
        indexingCoordinator.handleFoldersChanged()
    }

    func removeFolder(_ path: String) {
        settings = settingsStore.removeFolder(path)
        // Immediately purge removed folder data from both stores even when paused on battery or disabled.
        indexingCoordinator.pruneFolder(path)
        indexingCoordinator.startPass(force: false, restartIfRunning: true)
    }

    func addExcludedFolderViaPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.tr("settings.folders.exclude_prompt")
        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            settings = settingsStore.addExcludedFolder(url.path)
            indexingCoordinator.pruneFolder(url.path)
        }
        indexingCoordinator.startPass(force: false, restartIfRunning: true)
    }

    func removeExcludedFolder(_ path: String) {
        settings = settingsStore.removeExcludedFolder(path)
        indexingCoordinator.handleFoldersChanged()
    }

    func toggleOCREnabled(_ enabled: Bool) {
        settings.isOCREnabled = enabled
        settingsStore.save(settings)
        indexingCoordinator.startWatching()
        if enabled {
            indexingCoordinator.startPass(force: false, restartIfRunning: false)
        } else {
            ocrIndexer.cancelAllTasks()
            progress = ocrIndexer.currentSnapshot(state: .idle)
            onProgressUpdate?(progress)
        }
    }

    func toggleIndexOnBattery(_ enabled: Bool) {
        settings.indexOnBattery = enabled
        settingsStore.save(settings)
        // `powerMonitor.setIndexOnBattery` notifies `indexingCoordinator.handlePowerPolicyChange` when the blocker clears.
        powerMonitor.setIndexOnBattery(enabled)
    }

    func selectIndexingMode(_ mode: IndexingMode) {
        guard settings.indexingMode != mode else { return }
        settings.indexingMode = mode
        settingsStore.save(settings)
    }

    func triggerCoordinatedIndexNow() {
        indexingCoordinator.startPass(force: true)
    }

    func triggerIndexNow() {
        ocrIndexer.startIndexPass(force: true)
    }

    func revealFolderInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func reindexEmptyImages() {
        ocrIndexer.reindexEmptyImages()
    }

    func rebuildIndex() {
        ocrIndexer.rebuildIndex()
    }

    func toggleSemanticEnabled(_ enabled: Bool) {
        semanticSettings.isEnabled = enabled
        semanticSettingsStore.save(semanticSettings)
        indexingCoordinator.startWatching()
        if enabled {
            indexingCoordinator.startPass(force: false, restartIfRunning: false)
        } else {
            semanticIndexer.stopAndUnload()
            semanticProgress = semanticIndexer.currentSnapshot(state: .idle)
            onSemanticProgressUpdate?(semanticProgress)
        }
    }

    func selectSemanticModelsFolderViaPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.tr("settings.semantic.choose_folder_prompt")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        semanticSettings.customModelsDirectory = url.path
        semanticSettingsStore.save(semanticSettings)
        semanticIndexer.cancelAllTasks()
        semanticIndexer.unloadModels()
        semanticProgress = semanticIndexer.currentSnapshot()
        onSemanticProgressUpdate?(semanticProgress)
        if semanticSettings.isEnabled && semanticProgress.modelStatus.isReady {
            indexingCoordinator.startWatching()
            semanticIndexer.startIndexPass(force: true)
        }
    }

    func openSemanticModelDownloadPage() {
        NSWorkspace.shared.open(SemanticModelLocator.downloadPageURL)
    }

    func triggerSemanticIndexNow() {
        semanticIndexer.startIndexPass(force: true)
    }

    func rebuildSemanticIndex() {
        semanticIndexer.rebuildIndex()
    }

    func selectHotkeyPreset(_ preset: HotkeyPreset) {
        hotkeyManager.selectPreset(preset)
        syncHotkeyState()
        onExternalMenuSync()
    }

    func selectCustomShortcut(_ shortcut: HotkeyShortcut) {
        hotkeyManager.select(shortcut, persist: true)
        syncHotkeyState()
        onExternalMenuSync()
    }

    func switchToConflictFreeAlternative() {
        hotkeyManager.switchToConflictFreeAlternative()
        syncHotkeyState()
        onExternalMenuSync()
    }

    func openKeyboardSettings() {
        hotkeyManager.openKeyboardSettings()
    }

    func suspendHotkeyForRecording() {
        hotkeyManager.suspendForRecording()
    }

    func resumeHotkeyAfterRecording() {
        hotkeyManager.resumeAfterRecording()
        syncHotkeyState()
    }

    func beginHotkeyLiveMonitoring() {
        hotkeyManager.beginLiveMonitoring()
        syncHotkeyState()
    }

    func endHotkeyLiveMonitoring() {
        hotkeyManager.endLiveMonitoring()
    }

    func openSetupGuide() {
        onOpenSetupGuide?()
    }

    private func syncHotkeyState() {
        hotkeyShortcut = hotkeyManager.currentShortcut
        hotkeyConflict = hotkeyManager.activeConflict
        isSpotlightShortcutEnabled = hotkeyManager.isSpotlightShortcutEnabled
    }

    func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {}
        launchAtLogin = SMAppService.mainApp.status == .enabled
        onExternalMenuSync()
    }
}
