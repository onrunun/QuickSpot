import AppKit
import QuickSpotCore
import ServiceManagement
import SwiftUI

/// Drives the Settings & Indexing UI, syncing OCR folder preferences, power rules, hotkey, and login state.
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var settings: IndexSettings
    @Published var progress: IndexProgress
    @Published var hotkeyPreset: HotkeyPreset
    @Published var launchAtLogin: Bool
    @Published var appLanguage: AppLanguage
    @Published var clipboardEnabled: Bool
    @Published var clipboardCount: Int

    private let settingsStore: IndexSettingsStore
    private let ocrIndexer: ImageOCRIndexer
    private let clipboardHistory: ClipboardHistoryStore
    private let powerMonitor: PowerPolicyMonitor
    private let hotkeyManager: HotkeyManager
    private let onExternalMenuSync: () -> Void
    var onProgressUpdate: ((IndexProgress) -> Void)?

    init(
        settingsStore: IndexSettingsStore,
        ocrIndexer: ImageOCRIndexer,
        clipboardHistory: ClipboardHistoryStore = ClipboardHistoryStore(),
        powerMonitor: PowerPolicyMonitor,
        hotkeyManager: HotkeyManager,
        onExternalMenuSync: @escaping () -> Void
    ) {
        self.settingsStore = settingsStore
        self.ocrIndexer = ocrIndexer
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
        self.hotkeyPreset = hotkeyManager.currentPreset
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
    }

    func refreshSystemPreferences() {
        hotkeyPreset = hotkeyManager.currentPreset
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

    func selectLanguage(_ language: AppLanguage) {
        L10n.setLanguage(language)
        appLanguage = language
        if settings.isOCREnabled, case .paused = progress.state,
           let refreshedReason = PowerPolicyMonitor.blocker(indexOnBattery: settings.indexOnBattery) {
            progress = ocrIndexer.currentSnapshot(state: .paused(reason: refreshedReason))
            onProgressUpdate?(progress)
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
        ocrIndexer.startWatching(folders: settings.folders)
        ocrIndexer.startIndexPass(force: false)
    }

    func removeFolder(_ path: String) {
        settings = settingsStore.removeFolder(path)
        ocrIndexer.startWatching(folders: settings.folders)
        ocrIndexer.startIndexPass(force: false)
    }

    func toggleOCREnabled(_ enabled: Bool) {
        settings.isOCREnabled = enabled
        settingsStore.save(settings)
        if enabled {
            ocrIndexer.startWatching(folders: settings.folders)
            ocrIndexer.startIndexPass(force: false)
        } else {
            ocrIndexer.stopWatching()
            ocrIndexer.startIndexPass(force: false)
        }
    }

    func toggleIndexOnBattery(_ enabled: Bool) {
        settings.indexOnBattery = enabled
        settingsStore.save(settings)
        powerMonitor.setIndexOnBattery(enabled)
        if enabled {
            ocrIndexer.startIndexPass(force: false)
        }
    }

    func triggerIndexNow() {
        ocrIndexer.startIndexPass(force: true)
    }

    func reindexEmptyImages() {
        ocrIndexer.reindexEmptyImages()
    }

    func rebuildIndex() {
        ocrIndexer.rebuildIndex()
    }

    func selectHotkey(_ preset: HotkeyPreset) {
        hotkeyManager.register(preset: preset)
        hotkeyPreset = hotkeyManager.currentPreset
        onExternalMenuSync()
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
