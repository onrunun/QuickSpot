import Foundation
import os

/// Coordinates folder watching, incremental Apple Vision OCR indexing, and instant FTS5 query lookup.
public final class ImageOCRIndexer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.quickspot.core", category: "ImageOCRIndexer")
    private static let maxIncrementalBatch = 30
    private static let watcherDebounceSeconds: TimeInterval = 2.0

    private let store: ImageOCRStore
    private let settingsStore: IndexSettingsStore
    private let blockerProvider: @Sendable () -> String?
    private let lock = NSLock()

    private var activeTask: Task<Void, Never>?
    private var activePassToken: UInt64 = 0
    private var incrementalTask: Task<Void, Never>?
    private var folderWatcher: FSEventFolderWatcher?
    private var debounceWork: DispatchWorkItem?
    private var pendingChangedPaths: Set<String> = []
    private var progressHandler: (@Sendable (IndexProgress) -> Void)?

    public init(
        store: ImageOCRStore = ImageOCRStore(),
        settingsStore: IndexSettingsStore = IndexSettingsStore(),
        blockerProvider: @escaping @Sendable () -> String? = { nil },
        onProgress: (@Sendable (IndexProgress) -> Void)? = nil
    ) {
        self.store = store
        self.settingsStore = settingsStore
        self.blockerProvider = blockerProvider
        self.progressHandler = onProgress
    }

    deinit {
        stopWatching()
        lock.lock()
        activeTask?.cancel()
        incrementalTask?.cancel()
        lock.unlock()
    }

    public func setProgressHandler(_ handler: (@Sendable (IndexProgress) -> Void)?) {
        lock.lock(); progressHandler = handler; lock.unlock()
    }

    public func currentSnapshot(state: IndexProgress.State = .idle) -> IndexProgress {
        let s = store.stats()
        return IndexProgress(state: state, indexedCount: s.indexedCount, withTextCount: s.withTextCount)
    }

    public func startWatching(folders: [String]) {
        stopWatching()
        let excluded = settingsStore.load().excludedFolders
        let watcher = FSEventFolderWatcher(folders: folders, excludedPaths: excluded) { [weak self] paths in
            self?.handleWatcherEvents(paths)
        }
        lock.lock(); folderWatcher = watcher; lock.unlock()
    }

    public func stopWatching() {
        lock.lock()
        let current = folderWatcher; folderWatcher = nil
        debounceWork?.cancel(); debounceWork = nil
        pendingChangedPaths.removeAll()
        lock.unlock()
        current?.stop()
    }

    public func startIndexPass(force: Bool = false) {
        lock.lock()
        activeTask?.cancel()
        incrementalTask?.cancel()
        incrementalTask = nil
        activePassToken &+= 1
        let token = activePassToken
        let settings = settingsStore.load()
        guard settings.isOCREnabled else {
            activeTask = nil
            lock.unlock()
            emit(.idle)
            return
        }
        if !force, let reason = blockerProvider() {
            activeTask = nil
            lock.unlock()
            emit(.paused(reason: reason))
            return
        }
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runPass(
                folders: settings.folders,
                excludedFolders: settings.excludedFolders,
                force: force,
                token: token
            )
        }
        activeTask = task
        lock.unlock()
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

        let home = NSHomeDirectory()
        let fetchLimit = (filter == .imagesOnly || filter == .pdfOnly) ? limit * 3 : limit * 2
        let rawHits = store.search(query: query, limit: fetchLimit)

        let surviving = rawHits.filter { hit in
            let url = URL(fileURLWithPath: hit.path)
            return Self.matchesFilter(filter, url: url) && FileManager.default.fileExists(atPath: hit.path)
        }

        let queryTokens = Self.normalizedQueryTokens(from: query)
        let now = Date().timeIntervalSince1970

        let scored: [(index: Int, item: SearchItem)] = surviving.enumerated().map { idx, hit in
            let url = URL(fileURLWithPath: hit.path)
            let parent = url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~")
            let score = Self.calibratedOCRScore(
                rankIndex: idx, mtime: hit.mtime, now: now, fileName: hit.fileName, queryTokens: queryTokens
            )
            let item = SearchItem(
                id: "ocr:\(hit.path)", title: hit.fileName, subtitle: parent, category: .file,
                iconPath: hit.path, score: score, action: .openFile(url), previewURL: url,
                matchedSnippet: hit.excerpt.isEmpty ? nil : hit.excerpt, matchSource: .ocrContent
            )
            return (idx, item)
        }

        return scored
            .sorted { lhs, rhs in
                lhs.item.score != rhs.item.score ? lhs.item.score > rhs.item.score : lhs.index < rhs.index
            }
            .prefix(limit)
            .map(\.item)
    }

    private func cancelIndexingTasks() {
        lock.lock()
        activeTask?.cancel(); activeTask = nil
        incrementalTask?.cancel(); incrementalTask = nil
        lock.unlock()
    }

    private func runOffMainActor<T: Sendable>(
        fallback: T,
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        guard !Task.isCancelled else { return fallback }
        let worker = Task.detached(priority: .userInitiated) { () -> T in
            guard !Task.isCancelled else { return fallback }
            return work()
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func handleWatcherEvents(_ paths: [String]) {
        lock.lock()
        pendingChangedPaths.formUnion(paths)
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushWatcherEvents() }
        debounceWork = work
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.watcherDebounceSeconds,
            execute: work
        )
    }

    private func flushWatcherEvents() {
        lock.lock()
        let changed = Array(pendingChangedPaths)
        pendingChangedPaths.removeAll()
        debounceWork = nil
        lock.unlock()

        guard !changed.isEmpty else { return }
        if ImageFolderCrawler.canHandleIncrementally(changed, maxBatch: Self.maxIncrementalBatch) {
            startIncrementalPass(paths: changed)
        } else {
            startIndexPass(force: false)
        }
    }

    private func startIncrementalPass(paths: [String]) {
        let settings = settingsStore.load()
        guard settings.isOCREnabled else { return }
        if let reason = blockerProvider() {
            if !isFullPassActive() { emit(.paused(reason: reason)) }
            return
        }

        lock.lock()
        let previous = incrementalTask
        let task = Task.detached(priority: .utility) { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await self.runIncrementalPass(paths: paths, settings: settings)
        }
        incrementalTask = task
        lock.unlock()
    }

    private func runIncrementalPass(paths: [String], settings: IndexSettings) async {
        let existing = store.existingEntries()
        var toIndex: [DiscoveredImage] = []
        var toDelete: [String] = []
        var seen = Set<String>()

        for rawPath in paths {
            let stdPath = (rawPath as NSString).standardizingPath
            guard seen.insert(stdPath).inserted else { continue }
            if let item = ImageFolderCrawler.inspectSingleFile(
                at: stdPath,
                allowedRoots: settings.folders,
                excludedPaths: settings.excludedFolders
            ) {
                if let prev = existing[item.url.path],
                   prev.status == 1,
                   abs(prev.mtime - item.mtime) <= 0.001,
                   prev.size == item.size {
                    continue
                }
                toIndex.append(item)
            } else if existing[stdPath] != nil {
                toDelete.append(stdPath)
            }
        }

        if !toDelete.isEmpty { store.delete(paths: toDelete) }
        guard !toIndex.isEmpty else {
            if !toDelete.isEmpty && !isFullPassActive() { emit(.idle) }
            return
        }

        await indexPending(toIndex, force: false, onlyEmitWhenIdle: true)
    }

    private func runPass(
        folders: [String],
        excludedFolders: [String],
        force: Bool,
        token: UInt64
    ) async {
        defer { clearActiveTaskIfMatching(token: token) }
        emit(.scanning)
        let discovered = ImageFolderCrawler.crawl(folders: folders, excludedPaths: excludedFolders)
        guard !Task.isCancelled else { return }

        store.deleteMissing(keeping: Set(discovered.map(\.url.path)))
        let existing = store.existingEntries()
        let pending = discovered.filter { item in
            guard let prev = existing[item.url.path] else { return true }
            if prev.status == 0 { return true }
            return abs(prev.mtime - item.mtime) > 0.001 || prev.size != item.size
        }
        await indexPending(pending, force: force, onlyEmitWhenIdle: false)
    }

    private func indexPending(_ pending: [DiscoveredImage], force: Bool, onlyEmitWhenIdle: Bool) async {
        for (idx, item) in pending.enumerated() {
            if Task.isCancelled { return }
            if !force, let reason = blockerProvider() {
                if !onlyEmitWhenIdle || !isFullPassActive() { emit(.paused(reason: reason)) }
                return
            }
            indexDocument(item)
            if !onlyEmitWhenIdle || !isFullPassActive() { emit(.indexing(done: idx + 1, total: pending.count)) }
            await Task.yield()
        }
        if !Task.isCancelled && (!onlyEmitWhenIdle || !isFullPassActive()) { emit(.idle) }
    }

    private func indexDocument(_ item: DiscoveredImage) {
        switch VisionTextExtractor.extractTextResult(from: item.url) {
        case .success(let rawText):
            store.upsert(
                path: item.url.path,
                name: item.url.lastPathComponent,
                mtime: item.mtime,
                size: item.size,
                rawText: rawText,
                foldedText: VisionTextExtractor.normalizeForSearch(rawText),
                status: 1
            )
        case .failure(let error):
            Self.logger.warning(
                "OCR skipped for \(item.url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func isFullPassActive() -> Bool {
        lock.lock()
        let active = activeTask != nil
        lock.unlock()
        return active
    }

    private func clearActiveTaskIfMatching(token: UInt64) {
        lock.lock()
        if activePassToken == token { activeTask = nil }
        lock.unlock()
    }

    private func emit(_ state: IndexProgress.State) {
        let progress = currentSnapshot(state: state)
        lock.lock(); let handler = progressHandler; lock.unlock()
        handler?(progress)
    }
}
