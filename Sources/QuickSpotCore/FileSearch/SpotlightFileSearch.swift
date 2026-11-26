import Foundation

/// Queries macOS's native Spotlight index (NSMetadataQuery) using a fast dual-phase filename-first strategy.
@MainActor
public final class SpotlightFileSearch {
    private static let debounceNanoseconds: UInt64 = 30_000_000
    private static let maxScanCount = 400
    private static let maxCandidateCount = 60
    private static let maxReturnedCount = 25
    private static let contentFallbackThreshold = 6

    private let frecency: FrecencyStore
    private var activeQuery: NSMetadataQuery?
    private var debounceTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var searchGeneration: UInt64 = 0

    public init(frecency: FrecencyStore = FrecencyStore()) {
        self.frecency = frecency
    }

    public static func isExcludedPath(_ path: String, homeDirectory: String = NSHomeDirectory()) -> Bool {
        SpotlightQueryBuilder.isExcludedPath(path, homeDirectory: homeDirectory)
    }

    public static func turkishSearchVariants(for word: String) -> [String] {
        SpotlightQueryBuilder.turkishSearchVariants(for: word)
    }

    public func cancel() {
        searchGeneration &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        stopActiveQuery()
    }

    public func search(
        query: String,
        filter: SearchKindFilter? = nil,
        completion: @escaping @MainActor ([SearchItem]) -> Void
    ) {
        searchProgressive(query: query, filter: filter) { items, isFinished in
            guard isFinished else { return }
            completion(items)
        }
    }

    /// Paints Phase 1 filename matches immediately and optionally refines with Phase 2 content fallback.
    public func searchProgressive(
        query: String,
        filter: SearchKindFilter? = nil,
        onUpdate: @escaping @MainActor (_ items: [SearchItem], _ isFinished: Bool) -> Void
    ) {
        cancel()
        let generation = searchGeneration
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard filter != .appsOnly, filter != .clipboard, trimmed.count >= 2 else {
            onUpdate([], true)
            return
        }

        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled, let self, self.searchGeneration == generation else { return }
            self.startSearchPhases(term: trimmed, filter: filter, generation: generation, onUpdate: onUpdate)
        }
    }

    private func startSearchPhases(
        term: String,
        filter: SearchKindFilter?,
        generation: UInt64,
        onUpdate: @escaping @MainActor (_ items: [SearchItem], _ isFinished: Bool) -> Void
    ) {
        if filter == .contentOnly {
            executeSpotlightQuery(term: term, filter: filter, contentOnly: true, generation: generation) { [weak self] mdQuery in
                guard let self, self.searchGeneration == generation else { return }
                let items = self.collectResults(from: mdQuery, term: term, filter: filter, contentOnly: true, excludingPaths: [])
                self.stopActiveQuery()
                onUpdate(items, true)
            }
            return
        }

        executeSpotlightQuery(term: term, filter: filter, contentOnly: false, generation: generation) { [weak self] mdQuery in
            guard let self, self.searchGeneration == generation else { return }
            let phase1Items = self.collectResults(from: mdQuery, term: term, filter: filter, contentOnly: false, excludingPaths: [])
            self.stopActiveQuery()

            let allowsFallback = (filter == nil || filter == .filesOnly || filter == .pdfOnly)
            guard allowsFallback, term.count >= 3, phase1Items.count < Self.contentFallbackThreshold else {
                onUpdate(phase1Items, true)
                return
            }

            onUpdate(phase1Items, false)
            guard self.searchGeneration == generation else { return }

            let phase1Paths = Set(phase1Items.compactMap { $0.previewURL?.standardizedFileURL.path })
            self.executeSpotlightQuery(term: term, filter: filter, contentOnly: true, generation: generation) { [weak self] contentQuery in
                guard let self, self.searchGeneration == generation else { return }
                let phase2Items = self.collectResults(
                    from: contentQuery, term: term, filter: filter, contentOnly: true, excludingPaths: phase1Paths
                )
                self.stopActiveQuery()

                let merged = (phase1Items + phase2Items).sorted(by: Self.rankOrder)
                onUpdate(Array(merged.prefix(Self.maxReturnedCount)), true)
            }
        }
    }

    private func executeSpotlightQuery(
        term: String,
        filter: SearchKindFilter?,
        contentOnly: Bool,
        generation: UInt64,
        onFinished: @escaping @MainActor (NSMetadataQuery) -> Void
    ) {
        stopActiveQuery()

        let mdQuery = NSMetadataQuery()
        mdQuery.searchScopes = SpotlightQueryBuilder.buildSearchScopes()
        mdQuery.predicate = SpotlightQueryBuilder.buildPredicate(term: term, filter: filter, contentOnly: contentOnly)
        mdQuery.sortDescriptors = [NSSortDescriptor(key: kMDItemContentModificationDate as String, ascending: false)]
        mdQuery.notificationBatchingInterval = 0.04

        let queryID = ObjectIdentifier(mdQuery)
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: mdQuery,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      self.searchGeneration == generation,
                      let active = self.activeQuery,
                      ObjectIdentifier(active) == queryID else { return }
                onFinished(active)
            }
        }

        activeQuery = mdQuery
        mdQuery.start()
    }

    private func collectResults(
        from mdQuery: NSMetadataQuery,
        term: String,
        filter: SearchKindFilter?,
        contentOnly: Bool,
        excludingPaths: Set<String>
    ) -> [SearchItem] {
        mdQuery.disableUpdates()
        defer { mdQuery.enableUpdates() }

        let home = NSHomeDirectory()
        let now = Date()
        var seenPaths = excludingPaths
        var candidates: [SearchItem] = []
        let upperBound = min(mdQuery.resultCount, Self.maxScanCount)

        for idx in 0..<upperBound {
            guard let item = mdQuery.result(at: idx) as? NSMetadataItem,
                  let rawPath = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }

            let url = URL(fileURLWithPath: rawPath).standardizedFileURL
            let standardizedPath = url.path
            guard !Self.isExcludedPath(standardizedPath, homeDirectory: home),
                  seenPaths.insert(standardizedPath).inserted else { continue }

            let isFolder = Self.isFolderItem(item)
            if filter == .foldersOnly && !isFolder { continue }
            if (filter == .filesOnly || contentOnly) && isFolder { continue }

            let fileName = url.lastPathComponent
            let displayName = item.value(forAttribute: kMDItemDisplayName as String) as? String
            let lastUsed = item.value(forAttribute: kMDItemLastUsedDate as String) as? Date
            let modified = item.value(forAttribute: kMDItemContentModificationDate as String) as? Date
            let referenceDate = [lastUsed, modified].compactMap { $0 }.max()
            let frecencyBoost = frecency.boost(for: standardizedPath, query: term)

            let score = contentOnly
                ? SpotlightQueryBuilder.scoreContentMatch(
                    query: term, fileName: fileName, standardizedPath: standardizedPath,
                    referenceDate: referenceDate, frecencyBoost: frecencyBoost,
                    rankIndex: candidates.count, homeDirectory: home, now: now
                )
                : SpotlightQueryBuilder.scoreFilenameMatch(
                    query: term, fileName: fileName, displayName: displayName,
                    standardizedPath: standardizedPath, referenceDate: referenceDate,
                    frecencyBoost: frecencyBoost, homeDirectory: home, now: now
                )

            candidates.append(SearchItem(
                id: "file:\(standardizedPath)",
                title: fileName,
                subtitle: SpotlightQueryBuilder.formatParentSubtitle(for: url, homeDirectory: home),
                category: isFolder ? .folder : .file,
                iconPath: standardizedPath,
                score: score,
                action: .openFile(url),
                previewURL: url,
                matchedSnippet: contentOnly ? L10n.tr("snippet.file_content_match") : nil,
                matchSource: contentOnly ? .fileContent : .name
            ))
            if candidates.count >= Self.maxCandidateCount { break }
        }

        candidates.sort(by: Self.rankOrder)
        return Array(candidates.prefix(Self.maxReturnedCount))
    }

    private static func isFolderItem(_ item: NSMetadataItem) -> Bool {
        let contentType = item.value(forAttribute: kMDItemContentType as String) as? String
        let contentTypeTree = item.value(forAttribute: kMDItemContentTypeTree as String) as? [String] ?? []
        if contentTypeTree.contains("com.apple.package") { return false }
        return contentType == "public.folder" || contentTypeTree.contains("public.folder")
    }

    private static func rankOrder(_ lhs: SearchItem, _ rhs: SearchItem) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private func stopActiveQuery() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        activeQuery?.stop()
        activeQuery = nil
    }
}
