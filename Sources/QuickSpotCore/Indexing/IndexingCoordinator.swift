import Foundation

/// Coordinates a single FSEvents watcher, single folder crawl, and sequential OCR → Semantic Document → Semantic Visual execution
/// so both indexers never duplicate disk scans or collide on ANE/Metal thermal budgets.
public final class IndexingCoordinator: @unchecked Sendable {
    private static let maxIncrementalBatch = 30
    private static let watcherDebounceSeconds: TimeInterval = 2.0

    private let ocrIndexer: ImageOCRIndexer
    private let semanticIndexer: SemanticImageIndexer
    private let folderSettingsStore: IndexSettingsStore
    private let semanticSettingsStore: SemanticSettingsStore
    private let blockerProvider: @Sendable () -> String?
    private let pacer: IndexingPacer

    private let lock = NSLock()
    private var watchDebouncer: FolderWatchDebouncer?
    private var activePassTask: Task<Void, Never>?
    private var incrementalTask: Task<Void, Never>?
    private var activePassToken: UInt64 = 0
    private var activePassForced = false
    private var rescanRequestedAfterPass = false

    public init(
        ocrIndexer: ImageOCRIndexer,
        semanticIndexer: SemanticImageIndexer,
        folderSettingsStore: IndexSettingsStore = IndexSettingsStore(),
        semanticSettingsStore: SemanticSettingsStore = SemanticSettingsStore(),
        blockerProvider: @escaping @Sendable () -> String? = { nil },
        pacer: IndexingPacer? = nil
    ) {
        self.ocrIndexer = ocrIndexer
        self.semanticIndexer = semanticIndexer
        self.folderSettingsStore = folderSettingsStore
        self.semanticSettingsStore = semanticSettingsStore
        self.blockerProvider = blockerProvider
        self.pacer = pacer ?? IndexingPacer.live(settingsStore: folderSettingsStore)
    }

    deinit {
        stopWatching()
        lock.withLock {
            activePassTask?.cancel()
            incrementalTask?.cancel()
        }
    }

    /// Starts (or refreshes) the single shared FSEvents watcher for all configured folders.
    public func startWatching() {
        stopWatching()
        ocrIndexer.stopWatching()
        semanticIndexer.stopWatching()

        let folderSettings = folderSettingsStore.load()
        let semanticSettings = semanticSettingsStore.load()
        guard folderSettings.isOCREnabled || semanticSettings.isEnabled else { return }

        let debouncer = FolderWatchDebouncer(debounceSeconds: Self.watcherDebounceSeconds) { [weak self] batch in
            self?.handleFlushedBatch(batch)
        }
        debouncer.start(folders: folderSettings.folders, excludedPaths: folderSettings.excludedFolders)
        lock.withLock { watchDebouncer = debouncer }
    }

    public func stopWatching() {
        let active: FolderWatchDebouncer? = lock.withLock {
            let current = watchDebouncer
            watchDebouncer = nil
            return current
        }
        active?.stop()
    }

    /// Triggers a coordinated single-crawl pass (OCR → Semantic PDF/OCR Text → Semantic Visual Images).
    public func startPass(force: Bool = false, restartIfRunning: Bool = false) {
        let folderSettings = folderSettingsStore.load()
        let semanticSettings = semanticSettingsStore.load()
        let anyEnabled = folderSettings.isOCREnabled || semanticSettings.isEnabled

        lock.lock()
        if !anyEnabled {
            activePassTask?.cancel(); activePassTask = nil
            incrementalTask?.cancel(); incrementalTask = nil
            activePassForced = false
            rescanRequestedAfterPass = false
            lock.unlock()
            ocrIndexer.cancelAllTasks()
            semanticIndexer.stopAndUnload()
            ocrIndexer.emitCoordinatedState(.idle)
            return
        }

        if !force && activePassTask != nil && activePassForced {
            lock.unlock()
            return
        }

        if !force, let reason = blockerProvider() {
            if activePassTask != nil && !activePassForced {
                activePassTask?.cancel()
                activePassTask = nil
            }
            rescanRequestedAfterPass = false
            lock.unlock()
            emitPausedIfNotForced(reason: reason, folderSettings: folderSettings, semanticSettings: semanticSettings)
            return
        }

        if activePassTask != nil && !force && !restartIfRunning {
            rescanRequestedAfterPass = true
            lock.unlock()
            return
        }

        activePassTask?.cancel()
        activePassToken &+= 1
        let token = activePassToken
        activePassForced = force
        rescanRequestedAfterPass = false

        activePassTask = Task.detached(priority: pacer.taskPriority(force: force)) { [weak self] in
            guard let self else { return }
            await self.runCoordinatedPass(
                folders: folderSettings.folders,
                excludedFolders: folderSettings.excludedFolders,
                force: force,
                token: token
            )
        }
        lock.unlock()
    }

    /// Reacts to `PowerPolicyMonitor` transitions without cancelling explicit user-forced passes.
    public func handlePowerPolicyChange(blocker: String?) {
        if let reason = blocker {
            let folderSettings = folderSettingsStore.load()
            let semanticSettings = semanticSettingsStore.load()
            let wasForced: Bool = lock.withLock {
                let forced = activePassTask != nil && activePassForced
                if !forced {
                    activePassTask?.cancel()
                    activePassTask = nil
                    rescanRequestedAfterPass = false
                }
                return forced
            }
            if !wasForced {
                emitPausedIfNotForced(reason: reason, folderSettings: folderSettings, semanticSettings: semanticSettings)
            }
        } else {
            startPass(force: false, restartIfRunning: false)
        }
    }

    /// Immediately removes all entries under `folderPath` from OCR, visual, and document semantic stores, then refreshes watching.
    public func pruneFolder(_ folderPath: String) {
        ocrIndexer.pruneFolder(folderPath)
        semanticIndexer.pruneFolder(folderPath)
        startWatching()
    }

    /// Refreshes the shared watcher and schedules a coordinated pass after folder configuration changes.
    public func handleFoldersChanged() {
        startWatching()
        startPass(force: false, restartIfRunning: true)
    }

    private func runCoordinatedPass(
        folders: [String],
        excludedFolders: [String],
        force: Bool,
        token: UInt64
    ) async {
        defer { finishPass(token: token) }

        let folderSettings = folderSettingsStore.load()
        let runOCR = folderSettings.isOCREnabled
        let runSemantic = semanticSettingsStore.load().isEnabled
        guard runOCR || runSemantic else { return }

        if runOCR { ocrIndexer.emitCoordinatedState(.scanning) }
        let discovered = ImageFolderCrawler.crawl(
            folders: folders,
            excludedPaths: excludedFolders,
            throttleDelayProvider: { [pacer] in pacer.crawlThrottleDelay }
        )
        guard !Task.isCancelled else { return }

        // Stage 1: Vision OCR & digital PDF text extraction.
        if runOCR {
            await ocrIndexer.runCoordinatedPass(discovered: discovered, force: force)
        }
        guard !Task.isCancelled else { return }

        // Stage 2: EmbeddingGemma 2 text encoder on extracted PDF/OCR passages (310 MB text model only).
        if semanticSettingsStore.load().isEnabled {
            await semanticIndexer.runCoordinatedDocumentPass(force: force)
        }
        guard !Task.isCancelled else { return }

        // Stage 3: EmbeddingGemma 2 visual image embedding (loads mmproj, releases immediately on completion).
        if semanticSettingsStore.load().isEnabled {
            await semanticIndexer.runCoordinatedPass(discovered: discovered, force: force)
        }
    }

    private func finishPass(token: UInt64) {
        let shouldRescan: Bool = lock.withLock {
            guard activePassToken == token else { return false }
            activePassTask = nil
            activePassForced = false
            let pending = rescanRequestedAfterPass
            rescanRequestedAfterPass = false
            return pending
        }
        if shouldRescan {
            startPass(force: false, restartIfRunning: false)
        }
    }

    private func handleFlushedBatch(_ batch: FolderChangeBatch) {
        if !batch.requiresFullScan && ImageFolderCrawler.canHandleIncrementally(batch.paths, maxBatch: Self.maxIncrementalBatch) {
            enqueueSequentialIncremental(paths: batch.paths)
        } else {
            startPass(force: false, restartIfRunning: false)
        }
    }

    private func enqueueSequentialIncremental(paths: [String]) {
        lock.withLock {
            let previous = incrementalTask
            incrementalTask = Task.detached(priority: pacer.taskPriority(force: false)) { [weak self] in
                await previous?.value
                guard let self, !Task.isCancelled else { return }
                if self.folderSettingsStore.load().isOCREnabled {
                    await self.ocrIndexer.processIncremental(paths: paths)
                }
                guard !Task.isCancelled else { return }
                if self.semanticSettingsStore.load().isEnabled {
                    await self.semanticIndexer.processIncremental(paths: paths)
                }
            }
        }
    }

    private func emitPausedIfNotForced(
        reason: String,
        folderSettings: IndexSettings,
        semanticSettings: SemanticSettings
    ) {
        if folderSettings.isOCREnabled && !ocrIndexer.isForcedPassRunning {
            ocrIndexer.cancelNonForcedTasks()
            ocrIndexer.emitCoordinatedState(.paused(reason: reason))
        }
        if semanticSettings.isEnabled && !semanticIndexer.isForcedPassRunning {
            semanticIndexer.cancelNonForcedTasks()
            semanticIndexer.emitCoordinatedState(.paused(reason: reason))
        }
    }
}
