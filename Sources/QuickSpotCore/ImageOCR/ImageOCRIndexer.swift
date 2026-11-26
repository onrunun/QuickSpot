import Foundation
import os

/// Coordinates incremental Apple Vision OCR & PDF text indexing and instant FTS5 query lookup.
public final class ImageOCRIndexer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.quickspot.core", category: "ImageOCRIndexer")
    private static let maxIncrementalBatch = 30
    private static let watcherDebounceSeconds: TimeInterval = 2.0
    private static let progressEmitInterval: TimeInterval = 0.2

    private let store: ImageOCRStore
    private let settingsStore: IndexSettingsStore
    private let blockerProvider: @Sendable () -> String?
    private let pacer: IndexingPacer
    private let lock = NSLock()

    private var activeTask: Task<Void, Never>?
    private var activePassToken: UInt64 = 0
    private var activePassForced = false
    private var coordinatedPassActive = false
    private var incrementalTask: Task<Void, Never>?
    private var incrementalGeneration: UInt64 = 0
    private var watchDebouncer: FolderWatchDebouncer?
    private var progressHandler: (@Sendable (IndexProgress) -> Void)?

    public init(
        store: ImageOCRStore = ImageOCRStore(),
        settingsStore: IndexSettingsStore = IndexSettingsStore(),
        blockerProvider: @escaping @Sendable () -> String? = { nil },
        pacer: IndexingPacer? = nil,
        onProgress: (@Sendable (IndexProgress) -> Void)? = nil
    ) {
        self.store = store
        self.settingsStore = settingsStore
        self.blockerProvider = blockerProvider
        self.pacer = pacer ?? IndexingPacer.live(settingsStore: settingsStore)
        self.progressHandler = onProgress
    }

    deinit {
        stopWatching()
        lock.withLock {
            activeTask?.cancel()
            incrementalTask?.cancel()
        }
    }

    public func setProgressHandler(_ handler: (@Sendable (IndexProgress) -> Void)?) {
        lock.withLock { progressHandler = handler }
    }

    public func currentSnapshot(state: IndexProgress.State = .idle) -> IndexProgress {
        let s = store.stats()
        return IndexProgress(state: state, indexedCount: s.indexedCount, withTextCount: s.withTextCount)
    }

    public func startWatching(folders: [String]) {
        stopWatching()
        let excluded = settingsStore.load().excludedFolders
        let debouncer = FolderWatchDebouncer(debounceSeconds: Self.watcherDebounceSeconds) { [weak self] batch in
            self?.handleFlushedBatch(batch)
        }
        debouncer.start(folders: folders, excludedPaths: excluded)
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

    public func startIndexPass(force: Bool = false) {
        lock.lock()
        if !force && activeTask != nil && activePassForced {
            lock.unlock()
            return
        }
        activeTask?.cancel()
        incrementalTask?.cancel()
        incrementalTask = nil
        incrementalGeneration &+= 1
        activePassToken &+= 1
        let token = activePassToken
        let settings = settingsStore.load()
        guard settings.isOCREnabled else {
            activeTask = nil
            activePassForced = false
            lock.unlock()
            emit(.idle)
            return
        }
        if !force, let reason = blockerProvider() {
            activeTask = nil
            activePassForced = false
            lock.unlock()
            emit(.paused(reason: reason))
            return
        }
        activePassForced = force
        let task = Task.detached(priority: pacer.taskPriority(force: force)) { [weak self] in
            guard let self else { return }
            await self.runPass(folders: settings.folders, excludedFolders: settings.excludedFolders, force: force, token: token)
        }
        activeTask = task
        lock.unlock()
    }

    public func cancelAllTasks() { cancelIndexingTasks() }

    public func pruneFolder(_ folderPath: String) {
        store.deleteUnderFolder(folderPath)
        if !isFullPassActive() { emit(.idle) }
    }

    public func rebuildIndex() {
        cancelIndexingTasks()
        store.clearAll()
        startIndexPass(force: true)
    }

    public func reindexEmptyImages() {
        cancelIndexingTasks()
        store.resetEmptyImages()
        startIndexPass(force: true)
    }

    public func fullText(forPath path: String) -> String? { store.rawText(forPath: path) }

    public func fullTextAsync(forPath path: String) async -> String? {
        await runOffMainActor(fallback: nil) { self.fullText(forPath: path) }
    }

    public func searchAsync(query: String, filter: SearchKindFilter? = nil, limit: Int = 12) async -> [SearchItem] {
        await runOffMainActor(fallback: []) { self.search(query: query, filter: filter, limit: limit) }
    }

    public func search(query: String, filter: SearchKindFilter? = nil, limit: Int = 12) -> [SearchItem] {
        guard settingsStore.load().isOCREnabled else { return [] }
        if filter == .foldersOnly || filter == .appsOnly || filter == .clipboard { return [] }
        let rawHits = store.search(query: query, kind: OCRSearchHelpers.sqlKind(for: filter), limit: limit * 2)
        return OCRSearchHelpers.buildItems(from: rawHits, query: query, filter: filter, limit: limit)
    }

    // MARK: - Coordinated Hooks

    func emitCoordinatedState(_ state: IndexProgress.State) { emit(state) }

    func cancelNonForcedTasks() {
        lock.withLock {
            if activeTask != nil && !activePassForced {
                activeTask?.cancel()
                activeTask = nil
            }
            incrementalTask?.cancel()
            incrementalTask = nil
            incrementalGeneration &+= 1
        }
    }

    var isForcedPassRunning: Bool {
        lock.withLock { activeTask != nil && activePassForced }
    }

    func runCoordinatedPass(discovered: [DiscoveredImage], force: Bool) async {
        let settings = settingsStore.load()
        guard settings.isOCREnabled else { emit(.idle); return }
        if !force, let reason = blockerProvider() { emit(.paused(reason: reason)); return }
        lock.withLock { coordinatedPassActive = true }
        defer { lock.withLock { coordinatedPassActive = false } }
        await reconcileAndIndex(discovered: discovered, force: force)
    }

    func processIncremental(paths: [String]) async {
        let settings = settingsStore.load()
        guard settings.isOCREnabled else { return }
        let gen = lock.withLock { incrementalGeneration }
        await runIncrementalPass(paths: paths, settings: settings, generation: gen)
    }

    // MARK: - Private Pipeline

    private func handleFlushedBatch(_ batch: FolderChangeBatch) {
        if !batch.requiresFullScan && ImageFolderCrawler.canHandleIncrementally(batch.paths, maxBatch: Self.maxIncrementalBatch) {
            enqueueStandaloneIncremental(paths: batch.paths)
        } else {
            startIndexPass(force: false)
        }
    }

    private func enqueueStandaloneIncremental(paths: [String]) {
        let settings = settingsStore.load()
        guard settings.isOCREnabled else { return }
        lock.withLock {
            let previous = incrementalTask
            let gen = incrementalGeneration
            incrementalTask = Task.detached(priority: pacer.taskPriority(force: false)) { [weak self] in
                await previous?.value
                guard let self, !Task.isCancelled, self.isIncrementalGenerationCurrent(gen) else { return }
                await self.runIncrementalPass(paths: paths, settings: settings, generation: gen)
            }
        }
    }

    private func runIncrementalPass(paths: [String], settings: IndexSettings, generation: UInt64) async {
        let uniquePaths = Array(Set(paths.map { ($0 as NSString).standardizingPath }.filter { !$0.isEmpty }))
        guard !uniquePaths.isEmpty else { return }

        let existing = store.existingRecords(forPaths: uniquePaths)
        var toIndex: [DiscoveredImage] = []
        var toDelete: [String] = []
        for stdPath in uniquePaths {
            if let item = ImageFolderCrawler.inspectSingleFile(
                at: stdPath, allowedRoots: settings.folders, excludedPaths: settings.excludedFolders
            ) {
                if OCRSearchHelpers.needsIndexing(item: item, existing: existing[item.url.path]) {
                    toIndex.append(item)
                }
            } else if existing[stdPath] != nil {
                toDelete.append(stdPath)
            }
        }

        if !toDelete.isEmpty { store.delete(paths: toDelete) }
        guard !toIndex.isEmpty else {
            if !toDelete.isEmpty && !isFullPassActive() { emit(.idle) }
            return
        }
        if let reason = blockerProvider() {
            if !isFullPassActive() { emit(.paused(reason: reason)) }
            return
        }
        toIndex.sort { $0.mtime > $1.mtime }
        await indexPending(toIndex, force: false, onlyEmitWhenIdle: true, incrementalGeneration: generation)
    }

    private func runPass(folders: [String], excludedFolders: [String], force: Bool, token: UInt64) async {
        defer { clearActiveTaskIfMatching(token: token) }
        emit(.scanning)
        let discovered = ImageFolderCrawler.crawl(
            folders: folders,
            excludedPaths: excludedFolders,
            throttleDelayProvider: { [pacer] in pacer.crawlThrottleDelay }
        )
        guard !Task.isCancelled else { return }
        await reconcileAndIndex(discovered: discovered, force: force)
    }

    private func reconcileAndIndex(discovered: [DiscoveredImage], force: Bool) async {
        store.deleteMissing(keeping: Set(discovered.map(\.url.path)))
        let existing = store.existingRecords()
        let pending = discovered
            .filter { OCRSearchHelpers.needsIndexing(item: $0, existing: existing[$0.url.path]) }
            .sorted { $0.mtime > $1.mtime }
        await indexPending(pending, force: force, onlyEmitWhenIdle: false, incrementalGeneration: nil)
    }

    private func indexPending(
        _ pending: [DiscoveredImage],
        force: Bool,
        onlyEmitWhenIdle: Bool,
        incrementalGeneration: UInt64?
    ) async {
        guard !pending.isEmpty else {
            if !Task.isCancelled && (!onlyEmitWhenIdle || !isFullPassActive()) { emit(.idle) }
            return
        }
        var lastEmit = Date()
        if !onlyEmitWhenIdle || !isFullPassActive() {
            emit(.indexing(done: 0, total: pending.count))
        }
        for (idx, item) in pending.enumerated() {
            await pacer.waitBeforeWork()
            if Task.isCancelled || !settingsStore.load().isOCREnabled { return }
            if let gen = incrementalGeneration, !isIncrementalGenerationCurrent(gen) { return }
            if !force, let reason = blockerProvider() {
                if !onlyEmitWhenIdle || !isFullPassActive() { emit(.paused(reason: reason)) }
                return
            }
            let started = ProcessInfo.processInfo.systemUptime
            let completed = await indexDocument(item, force: force, incrementalGeneration: incrementalGeneration)
            guard completed else {
                if !force, let reason = blockerProvider(), !Task.isCancelled {
                    if !onlyEmitWhenIdle || !isFullPassActive() { emit(.paused(reason: reason)) }
                }
                return
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let done = idx + 1
            let now = Date()
            if done == pending.count || now.timeIntervalSince(lastEmit) >= Self.progressEmitInterval {
                lastEmit = now
                if !onlyEmitWhenIdle || !isFullPassActive() { emit(.indexing(done: done, total: pending.count)) }
            }
            if done < pending.count {
                await pacer.cooldownAfterWork(for: .ocr, workDuration: elapsed, force: force)
            } else {
                await Task.yield()
            }
        }
        if !Task.isCancelled && (!onlyEmitWhenIdle || !isFullPassActive()) { emit(.idle) }
    }

    private func indexDocument(
        _ item: DiscoveredImage,
        force: Bool,
        incrementalGeneration: UInt64?
    ) async -> Bool {
        let result = await VisionTextExtractor.extractTextResultAsync(
            from: item.url,
            shouldContinue: { [weak self] in
                guard let self else { return false }
                await self.pacer.waitBeforeWork()
                if Task.isCancelled || !self.settingsStore.load().isOCREnabled { return false }
                if let gen = incrementalGeneration, !self.isIncrementalGenerationCurrent(gen) { return false }
                if !force && self.blockerProvider() != nil { return false }
                return true
            },
            afterOCRUnit: { [pacer] elapsed in
                await pacer.cooldownAfterWork(for: .ocr, workDuration: elapsed, force: force)
            }
        )
        switch result {
        case .success(let rawText):
            store.upsert(
                path: item.url.path, name: item.url.lastPathComponent,
                mtime: item.mtime, size: item.size,
                rawText: rawText, foldedText: VisionTextExtractor.normalizeForSearch(rawText),
                status: ImageOCRStore.statusIndexed
            )
            return true
        case .failure(is CancellationError):
            return false
        case .failure(let error):
            store.recordFailure(path: item.url.path, name: item.url.lastPathComponent, mtime: item.mtime, size: item.size)
            Self.logger.warning(
                "OCR skipped for \(item.url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)"
            )
            return true
        }
    }

    private func cancelIndexingTasks() {
        lock.withLock {
            activeTask?.cancel(); activeTask = nil
            activePassForced = false
            incrementalTask?.cancel(); incrementalTask = nil
            incrementalGeneration &+= 1
        }
    }

    private func runOffMainActor<T: Sendable>(fallback: T, _ work: @escaping @Sendable () -> T) async -> T {
        guard !Task.isCancelled else { return fallback }
        let worker = Task.detached(priority: .userInitiated) { () -> T in
            guard !Task.isCancelled else { return fallback }
            return work()
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    private func isFullPassActive() -> Bool { lock.withLock { activeTask != nil || coordinatedPassActive } }
    private func isIncrementalGenerationCurrent(_ gen: UInt64) -> Bool { lock.withLock { incrementalGeneration == gen } }

    private func clearActiveTaskIfMatching(token: UInt64) {
        lock.withLock {
            if activePassToken == token { activeTask = nil; activePassForced = false }
        }
    }

    private func emit(_ state: IndexProgress.State) {
        let progress = currentSnapshot(state: state)
        let handler = lock.withLock { progressHandler }
        handler?(progress)
    }
}
