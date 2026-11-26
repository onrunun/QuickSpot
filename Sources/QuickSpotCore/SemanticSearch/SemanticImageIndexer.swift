import CoreGraphics
import Foundation
import os

/// Coordinates local EmbeddingGemma 2 visual image + semantic PDF/OCR document embedding and sub-millisecond vector search.
public final class SemanticImageIndexer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.quickspot.core", category: "SemanticImageIndexer")
    private static let maxIncrementalBatch = 30
    private static let watcherDebounceSeconds: TimeInterval = 2.5
    private static let progressEmitInterval: TimeInterval = 0.2

    /// Empirical EmbeddingGemma 2 cross-modal cosine similarity cutoffs calibrated on real photos + negative queries.
    public static let defaultGeneralMinSimilarity: Float = 0.650
    public static let defaultImageFilterMinSimilarity: Float = 0.635
    public static let defaultSimilarImageMinSimilarity: Float = 0.650
    public static let defaultSimilarDocumentMinSimilarity: Float = 0.680
    public static let relativeMarginFromTop: Float = 0.042
    public static let minCorpusSizeForZScore = 20
    public static let generalMinZScore: Float = 2.3
    public static let imageFilterMinZScore: Float = 1.6

    private let store: SemanticVectorStore
    private let documentIndexer: SemanticDocumentIndexer?
    private let engine: SemanticEmbeddingProvider
    private let similarityService: SemanticSimilarityService
    private let folderSettingsStore: IndexSettingsStore
    private let semanticSettingsStore: SemanticSettingsStore
    private let blockerProvider: @Sendable () -> String?
    private let pacer: IndexingPacer
    private let generalMinSimilarity: Float
    private let imageFilterMinSimilarity: Float

    private let lock = NSLock()
    private var activeTask: Task<Void, Never>?
    private var activePassToken: UInt64 = 0
    private var activePassForced = false
    private var coordinatedPassActive = false
    private var incrementalTask: Task<Void, Never>?
    private var incrementalGeneration: UInt64 = 0
    private var watchDebouncer: FolderWatchDebouncer?
    private var progressHandler: (@Sendable (SemanticIndexProgress) -> Void)?

    public init(
        store: SemanticVectorStore = SemanticVectorStore(),
        documentIndexer: SemanticDocumentIndexer? = nil,
        engine: SemanticEmbeddingProvider? = nil,
        folderSettingsStore: IndexSettingsStore = IndexSettingsStore(),
        semanticSettingsStore: SemanticSettingsStore = SemanticSettingsStore(),
        blockerProvider: @escaping @Sendable () -> String? = { nil },
        pacer: IndexingPacer? = nil,
        generalMinSimilarity: Float = SemanticImageIndexer.defaultGeneralMinSimilarity,
        imageFilterMinSimilarity: Float = SemanticImageIndexer.defaultImageFilterMinSimilarity,
        similarImageMinSimilarity: Float = SemanticImageIndexer.defaultSimilarImageMinSimilarity,
        similarDocumentMinSimilarity: Float = SemanticImageIndexer.defaultSimilarDocumentMinSimilarity,
        onProgress: (@Sendable (SemanticIndexProgress) -> Void)? = nil
    ) {
        let resolvedEngine = engine ?? SemanticEmbeddingEngine(settingsStore: semanticSettingsStore)
        self.store = store
        self.documentIndexer = documentIndexer
        self.engine = resolvedEngine
        self.similarityService = SemanticSimilarityService(
            store: store,
            documentIndexer: documentIndexer,
            engine: resolvedEngine,
            semanticSettingsStore: semanticSettingsStore,
            imageMinSimilarity: similarImageMinSimilarity,
            documentMinSimilarity: similarDocumentMinSimilarity
        )
        self.folderSettingsStore = folderSettingsStore
        self.semanticSettingsStore = semanticSettingsStore
        self.blockerProvider = blockerProvider
        self.pacer = pacer ?? IndexingPacer.live(settingsStore: folderSettingsStore)
        self.generalMinSimilarity = generalMinSimilarity
        self.imageFilterMinSimilarity = imageFilterMinSimilarity
        self.progressHandler = onProgress
    }

    deinit {
        stopWatching()
        lock.withLock {
            activeTask?.cancel()
            incrementalTask?.cancel()
        }
    }

    public func setProgressHandler(_ handler: (@Sendable (SemanticIndexProgress) -> Void)?) {
        lock.withLock { progressHandler = handler }
    }

    public func currentSnapshot(state: SemanticIndexProgress.State? = nil) -> SemanticIndexProgress {
        let status = resolvedModelStatusSync()
        let resolvedState = state ?? (status.isReady ? .idle : .modelsMissing)
        return SemanticIndexProgress(
            state: resolvedState,
            embeddedCount: store.count(forModelID: engine.modelIdentifier),
            modelStatus: status,
            embeddedDocumentCount: documentIndexer?.documentCount() ?? 0
        )
    }

    public func startWatching(folders: [String]) {
        stopWatching()
        guard semanticSettingsStore.load().isEnabled else { return }
        let excluded = folderSettingsStore.load().excludedFolders
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
        let semanticSettings = semanticSettingsStore.load()
        let folderSettings = folderSettingsStore.load()

        guard semanticSettings.isEnabled else {
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
            await self.runPass(
                folders: folderSettings.folders, excludedFolders: folderSettings.excludedFolders,
                force: force, token: token
            )
        }
        activeTask = task
        lock.unlock()
    }

    public func stopAndUnload() {
        stopWatching()
        cancelIndexingTasks()
        unloadModels()
        emit(.idle)
    }

    public func cancelAllTasks() { cancelIndexingTasks() }

    public func pruneFolder(_ folderPath: String) {
        store.deleteUnderFolder(folderPath)
        documentIndexer?.pruneFolder(folderPath)
        if !isFullPassActive() { emit(.idle) }
    }

    public func rebuildIndex() {
        cancelIndexingTasks()
        store.clearAll()
        documentIndexer?.clearAll()
        startIndexPass(force: true)
    }

    public func unloadModels() {
        Task.detached(priority: .utility) { [engine] in await engine.unloadAll() }
    }

    /// Runs unified local semantic search across both visual image embeddings and PDF/OCR document chunk embeddings
    /// using a single shared query embedding pass, with optional `-term` negative concept exclusion.
    public func searchAsync(
        query: String,
        filter: SearchKindFilter? = nil,
        limit: Int = 10
    ) async -> [SearchItem] {
        let parsed = SemanticQueryExpression.parse(query)
        let trimmed = parsed.positiveQuery
        guard trimmed.count >= 2, limit > 0 else { return [] }
        guard semanticSettingsStore.load().isEnabled else { return [] }
        if filter == .foldersOnly || filter == .appsOnly || filter == .clipboard { return [] }

        let canSearchVisual = (filter != .pdfOnly) && store.count(forModelID: engine.modelIdentifier) > 0
        let canSearchDocs = (documentIndexer?.documentCount() ?? 0) > 0
        guard canSearchVisual || canSearchDocs else { return [] }
        guard await engine.isTextModelReady() else { return [] }

        var queryVectors: [[Float]] = []
        var negativeVectors: [[Float]] = []
        do {
            queryVectors.append(try await engine.embedQuery(trimmed))
            if let restored = await TurkishQueryRestorer.restoredVariantAsync(for: trimmed),
               restored.caseInsensitiveCompare(trimmed) != .orderedSame,
               !Task.isCancelled {
                queryVectors.append(try await engine.embedQuery(restored))
            }
            for neg in parsed.negativeTerms {
                guard !Task.isCancelled else { return [] }
                negativeVectors.append(try await engine.embedQuery(neg))
                if let restoredNeg = await TurkishQueryRestorer.restoredVariantAsync(for: neg),
                   restoredNeg.caseInsensitiveCompare(neg) != .orderedSame,
                   !Task.isCancelled {
                    negativeVectors.append(try await engine.embedQuery(restoredNeg))
                }
            }
        } catch is CancellationError {
            return []
        } catch {
            Self.logger.warning("Semantic query embed failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        guard !Task.isCancelled else { return [] }

        var visualItems: [SearchItem] = []
        if canSearchVisual {
            let threshold = (filter == .imagesOnly) ? imageFilterMinSimilarity : generalMinSimilarity
            let minZ = (filter == .imagesOnly) ? Self.imageFilterMinZScore : Self.generalMinZScore
            let fetchLimit = (filter == .imagesOnly) ? limit * 3 : limit * 2
            let searchResult = store.searchWithStats(
                queryVectors: queryVectors,
                negativeVectors: negativeVectors,
                modelID: engine.modelIdentifier,
                limit: fetchLimit,
                minSimilarity: threshold
            )
            visualItems = SemanticSearchScorer.buildItems(
                from: searchResult, query: trimmed, threshold: threshold, minZScore: minZ,
                relativeMargin: Self.relativeMarginFromTop, minCorpusForZScore: Self.minCorpusSizeForZScore, limit: limit
            ).filter { !parsed.matchesNegativeTerm(in: $0.title) }
        }

        let docItems = canSearchDocs
            ? (documentIndexer?.search(
                queryVectors: queryVectors,
                negativeVectors: negativeVectors,
                query: trimmed,
                filter: filter,
                limit: limit
            ) ?? []).filter { !parsed.matchesNegativeTerm(in: $0.title) }
            : []

        return Self.mergeSemanticItems(visual: visualItems, documents: docItems, limit: limit)
    }

    /// Returns the supported similarity target kind when `url` can anchor a local "Find Similar" search.
    public func similarityTargetKind(for url: URL) -> SimilarityTargetKind? {
        similarityService.targetKind(for: url)
    }

    /// Returns true when at least one visual or document embedding exists to answer clipboard reverse-image searches.
    public func canSearchClipboardImage() -> Bool {
        similarityService.canSearchClipboardImage()
    }

    /// Returns true when both image and document embeddings are present, enabling cross-modal scope toggles.
    public func hasBothModalitiesIndexed() -> Bool {
        similarityService.hasBothModalitiesIndexed()
    }

    /// Finds visually, semantically, or cross-modally similar images/documents for `url`, optionally narrowed by hybrid text refinement.
    public func findSimilarAsync(
        to url: URL,
        kind: SimilarityTargetKind? = nil,
        scope: SimilaritySearchScope? = nil,
        refinementQuery: String? = nil,
        limit: Int = 18
    ) async -> SimilaritySearchResult {
        await similarityService.findSimilar(
            to: url,
            kind: kind,
            scope: scope,
            refinementQuery: refinementQuery,
            limit: limit
        )
    }

    /// Embeds an in-memory clipboard `CGImage` once so subsequent refinement/scope changes stay sub-millisecond.
    public func embedClipboardImageAsync(_ cgImage: CGImage) async -> (vector: [Float]?, status: SimilaritySearchResult.Status) {
        await similarityService.embedClipboardImage(cgImage)
    }

    /// Searches similar images/documents using an already-computed source vector (e.g. from a clipboard image).
    public func findSimilarByVectorAsync(
        _ sourceVector: [Float],
        sourceKind: SimilarityTargetKind = .image,
        excludePath: String? = nil,
        scope: SimilaritySearchScope = .images,
        refinementQuery: String? = nil,
        limit: Int = 18
    ) async -> SimilaritySearchResult {
        await similarityService.searchByVector(
            sourceVector,
            sourceKind: sourceKind,
            excludePath: excludePath,
            scope: scope,
            refinementQuery: refinementQuery,
            limit: limit
        )
    }

    /// Scans stored image embeddings off-lock to detect near-duplicate / recompressed photo groups.
    public func findNearDuplicateImagesAsync(
        threshold: Float = SemanticDuplicateFinder.defaultThreshold,
        maxGroups: Int = 80
    ) async -> [NearDuplicateGroup] {
        let modelID = engine.modelIdentifier
        let dim = engine.dimension
        let storeRef = store
        return await Task.detached(priority: .userInitiated) {
            SemanticDuplicateFinder.findGroups(
                in: storeRef,
                modelID: modelID,
                dimension: dim,
                threshold: threshold,
                maxGroups: maxGroups
            )
        }.value
    }

    /// Removes trashed or deleted paths from the visual and document vector stores immediately.
    public func removeIndexedPaths(_ paths: [String]) {
        let standardized = paths.map { ($0 as NSString).standardizingPath }.filter { !$0.isEmpty }
        guard !standardized.isEmpty else { return }
        store.delete(paths: standardized)
        documentIndexer?.removePaths(standardized)
        if !isFullPassActive() { emit(.idle) }
    }

    public static func calibratedSemanticScore(
        similarity: Float, topSimilarity: Float, rankIndex: Int,
        mtime: Double, now: Double, fileName: String, queryTokens: [String]
    ) -> Int {
        SemanticSearchScorer.calibratedScore(
            similarity: similarity, topSimilarity: topSimilarity, rankIndex: rankIndex,
            mtime: mtime, now: now, fileName: fileName, queryTokens: queryTokens
        )
    }

    // MARK: - Coordinated Hooks

    func emitCoordinatedState(_ state: SemanticIndexProgress.State) { emit(state) }

    func cancelNonForcedTasks() {
        lock.withLock {
            if activeTask != nil && !activePassForced { activeTask?.cancel(); activeTask = nil }
            incrementalTask?.cancel(); incrementalTask = nil
            incrementalGeneration &+= 1
        }
    }

    var isForcedPassRunning: Bool { lock.withLock { activeTask != nil && activePassForced } }

    func runCoordinatedDocumentPass(force: Bool) async {
        guard let documentIndexer, semanticSettingsStore.load().isEnabled else { return }
        if !force, let reason = blockerProvider() {
            emit(.paused(reason: reason))
            return
        }
        lock.withLock { coordinatedPassActive = true }
        defer { lock.withLock { coordinatedPassActive = false } }
        await documentIndexer.reconcileAll(
            force: force,
            blockerProvider: blockerProvider,
            isEnabled: { [semanticSettingsStore] in semanticSettingsStore.load().isEnabled },
            onProgress: { [weak self] done, total in
                self?.emit(.indexing(done: done, total: total))
            }
        )
        if !Task.isCancelled { emit(.idle) }
    }

    func runCoordinatedPass(discovered: [DiscoveredImage], force: Bool) async {
        guard semanticSettingsStore.load().isEnabled else { emit(.idle); return }
        let status = await engine.modelStatus()
        guard status.isReady else { emit(.modelsMissing, status: status); return }
        if !force, let reason = blockerProvider() { emit(.paused(reason: reason), status: status); return }

        lock.withLock { coordinatedPassActive = true }
        defer { lock.withLock { coordinatedPassActive = false } }

        let images = discovered.filter { VisionTextExtractor.isSupportedImage($0.url) }
        await reconcileAndEmbed(discoveredImages: images, force: force, status: status)
    }

    func processIncremental(paths: [String]) async {
        guard semanticSettingsStore.load().isEnabled else { return }
        let folderSettings = folderSettingsStore.load()
        let gen = lock.withLock { incrementalGeneration }
        await documentIndexer?.reconcileIncremental(
            paths: paths,
            blockerProvider: blockerProvider,
            isEnabled: { [semanticSettingsStore] in semanticSettingsStore.load().isEnabled }
        )
        await runIncrementalPass(paths: paths, folderSettings: folderSettings, generation: gen)
    }

    // MARK: - Private Pipeline

    private func runPass(folders: [String], excludedFolders: [String], force: Bool, token: UInt64) async {
        defer { clearActiveTaskIfMatching(token: token) }
        await documentIndexer?.reconcileAll(
            force: force,
            blockerProvider: blockerProvider,
            isEnabled: { [semanticSettingsStore] in semanticSettingsStore.load().isEnabled },
            onProgress: { [weak self] done, total in
                self?.emit(.indexing(done: done, total: total))
            }
        )
        guard !Task.isCancelled else { return }

        let status = await engine.modelStatus()
        guard status.isReady else { emit(.modelsMissing, status: status); return }
        emit(.scanning, status: status)
        let discovered = ImageFolderCrawler.crawl(
            folders: folders,
            excludedPaths: excludedFolders,
            throttleDelayProvider: { [pacer] in pacer.crawlThrottleDelay }
        )
        .filter { VisionTextExtractor.isSupportedImage($0.url) }
        guard !Task.isCancelled else { return }
        await reconcileAndEmbed(discoveredImages: discovered, force: force, status: status)
    }

    private func reconcileAndEmbed(discoveredImages: [DiscoveredImage], force: Bool, status: SemanticModelStatus) async {
        store.deleteMissing(keeping: Set(discoveredImages.map(\.url.path)))
        let existing = store.existingEntries()
        let activeModelID = engine.modelIdentifier
        let pending = discoveredImages
            .filter { Self.needsEmbedding(item: $0, existing: existing[$0.url.path], activeModelID: activeModelID) }
            .sorted { $0.mtime > $1.mtime }
        await embedPending(pending, force: force, status: status, onlyEmitWhenIdle: false, incrementalGeneration: nil)
    }

    private func embedPending(
        _ pending: [DiscoveredImage], force: Bool, status: SemanticModelStatus,
        onlyEmitWhenIdle: Bool, incrementalGeneration: UInt64?
    ) async {
        guard !pending.isEmpty else {
            if !Task.isCancelled && (!onlyEmitWhenIdle || !isFullPassActive()) { emit(.idle, status: status) }
            return
        }

        let total = pending.count
        let activeModelID = engine.modelIdentifier
        var lastEmit = Date()
        if !onlyEmitWhenIdle || !isFullPassActive() {
            emit(.indexing(done: 0, total: total), status: status)
        }
        var index = 0

        while index < total {
            await pacer.waitBeforeWork()
            if Task.isCancelled || !semanticSettingsStore.load().isEnabled {
                await engine.releaseImageEncoder(); return
            }
            if let gen = incrementalGeneration, !isIncrementalGenerationCurrent(gen) {
                await engine.releaseImageEncoder(); return
            }
            if !force, let reason = blockerProvider() {
                await engine.releaseImageEncoder()
                if !onlyEmitWhenIdle || !isFullPassActive() { emit(.paused(reason: reason), status: status) }
                return
            }

            let batchSize = max(1, pacer.batchSize(for: .semanticVisual))
            let end = min(index + batchSize, total)
            let slice = Array(pending[index..<end])
            let byPath = Dictionary(uniqueKeysWithValues: slice.map { ($0.url.path, $0) })
            let started = ProcessInfo.processInfo.systemUptime

            do {
                let results = try await engine.embedImages(slice.map(\.url))
                var upserts: [SemanticVectorUpsert] = []
                var succeeded = Set<String>()
                for (url, vector) in results {
                    if let meta = byPath[url.path] {
                        succeeded.insert(meta.url.path)
                        upserts.append(SemanticVectorUpsert(
                            path: meta.url.path, name: meta.url.lastPathComponent,
                            mtime: meta.mtime, size: meta.size, modelID: activeModelID, vector: vector
                        ))
                    }
                }
                if !upserts.isEmpty { store.upsertBatch(upserts) }
                let failed = slice.compactMap { item -> (path: String, name: String, mtime: Double, size: Int64)? in
                    succeeded.contains(item.url.path) ? nil : (item.url.path, item.url.lastPathComponent, item.mtime, item.size)
                }
                if !failed.isEmpty { store.recordFailures(failed, modelID: activeModelID) }
            } catch is CancellationError {
                await engine.releaseImageEncoder(); return
            } catch {
                Self.logger.warning("Semantic batch embed error: \(error.localizedDescription, privacy: .public)")
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - started
            index = end
            let now = Date()
            if index == total || now.timeIntervalSince(lastEmit) >= Self.progressEmitInterval {
                lastEmit = now
                if !onlyEmitWhenIdle || !isFullPassActive() { emit(.indexing(done: index, total: total), status: status) }
            }
            if index < total {
                await pacer.cooldownAfterWork(for: .semanticVisual, workDuration: elapsed, force: force)
            } else {
                await Task.yield()
            }
        }

        await engine.releaseImageEncoder()
        if !Task.isCancelled && (!onlyEmitWhenIdle || !isFullPassActive()) { emit(.idle, status: status) }
    }

    private func handleFlushedBatch(_ batch: FolderChangeBatch) {
        if !batch.requiresFullScan && ImageFolderCrawler.canHandleIncrementally(batch.paths, maxBatch: Self.maxIncrementalBatch) {
            enqueueStandaloneIncremental(paths: batch.paths)
        } else {
            startIndexPass(force: false)
        }
    }

    private func enqueueStandaloneIncremental(paths: [String]) {
        guard semanticSettingsStore.load().isEnabled else { return }
        let folderSettings = folderSettingsStore.load()
        lock.withLock {
            let previous = incrementalTask
            let gen = incrementalGeneration
            incrementalTask = Task.detached(priority: pacer.taskPriority(force: false)) { [weak self] in
                await previous?.value
                guard let self, !Task.isCancelled, self.isIncrementalGenerationCurrent(gen) else { return }
                await self.runIncrementalPass(paths: paths, folderSettings: folderSettings, generation: gen)
            }
        }
    }

    private func runIncrementalPass(paths: [String], folderSettings: IndexSettings, generation: UInt64) async {
        let uniquePaths = Array(Set(paths.map { ($0 as NSString).standardizingPath }.filter { !$0.isEmpty }))
        guard !uniquePaths.isEmpty else { return }

        let existing = store.existingEntries(forPaths: uniquePaths)
        let activeModelID = engine.modelIdentifier
        var toEmbed: [DiscoveredImage] = []
        var toDelete: [String] = []
        for stdPath in uniquePaths {
            if let item = ImageFolderCrawler.inspectSingleFile(
                at: stdPath, allowedRoots: folderSettings.folders, excludedPaths: folderSettings.excludedFolders
            ), VisionTextExtractor.isSupportedImage(item.url) {
                if Self.needsEmbedding(item: item, existing: existing[item.url.path], activeModelID: activeModelID) {
                    toEmbed.append(item)
                }
            } else if existing[stdPath] != nil {
                toDelete.append(stdPath)
            }
        }

        if !toDelete.isEmpty { store.delete(paths: toDelete) }
        guard !toEmbed.isEmpty else {
            if !toDelete.isEmpty && !isFullPassActive() { emit(.idle) }
            return
        }
        let status = await engine.modelStatus()
        guard status.isReady else { return }
        if let reason = blockerProvider() {
            if !isFullPassActive() { emit(.paused(reason: reason), status: status) }
            return
        }
        toEmbed.sort { $0.mtime > $1.mtime }
        await embedPending(toEmbed, force: false, status: status, onlyEmitWhenIdle: true, incrementalGeneration: generation)
    }

    private static func needsEmbedding(item: DiscoveredImage, existing: SemanticStoreEntry?, activeModelID: String) -> Bool {
        guard let prev = existing else { return true }
        if prev.modelID != activeModelID { return true }
        if abs(prev.mtime - item.mtime) > 0.001 || prev.size != item.size { return true }
        return prev.status == SemanticVectorStore.statusFailed && prev.retryCount < SemanticVectorStore.maxFailureRetries
    }

    private static func mergeSemanticItems(visual: [SearchItem], documents: [SearchItem], limit: Int) -> [SearchItem] {
        if documents.isEmpty { return Array(visual.prefix(limit)) }
        if visual.isEmpty { return Array(documents.prefix(limit)) }
        var byPath: [String: SearchItem] = [:]
        for item in documents + visual {
            let key = item.previewURL?.path ?? item.id
            if let existing = byPath[key] {
                if item.score > existing.score {
                    byPath[key] = item
                }
            } else {
                byPath[key] = item
            }
        }
        return byPath.values.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    private func cancelIndexingTasks() {
        lock.withLock {
            activeTask?.cancel(); activeTask = nil
            activePassForced = false
            incrementalTask?.cancel(); incrementalTask = nil
            incrementalGeneration &+= 1
        }
    }

    private func isFullPassActive() -> Bool { lock.withLock { activeTask != nil || coordinatedPassActive } }
    private func isIncrementalGenerationCurrent(_ gen: UInt64) -> Bool { lock.withLock { incrementalGeneration == gen } }

    private func clearActiveTaskIfMatching(token: UInt64) {
        lock.withLock {
            if activePassToken == token { activeTask = nil; activePassForced = false }
        }
    }

    private func resolvedModelStatusSync() -> SemanticModelStatus {
        SemanticModelLocator.resolve(customDirectory: semanticSettingsStore.load().customModelsDirectory)
    }

    private func emit(_ state: SemanticIndexProgress.State, status: SemanticModelStatus? = nil) {
        let resolvedStatus = status ?? resolvedModelStatusSync()
        let progress = SemanticIndexProgress(
            state: state,
            embeddedCount: store.count(forModelID: engine.modelIdentifier),
            modelStatus: resolvedStatus,
            embeddedDocumentCount: documentIndexer?.documentCount() ?? 0
        )
        let handler = lock.withLock { progressHandler }
        handler?(progress)
    }
}
