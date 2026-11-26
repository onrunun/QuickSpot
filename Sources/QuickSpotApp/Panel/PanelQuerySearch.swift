import Foundation
import QuickSpotCore

/// Isolates QueryParser-driven routing across empty home state, paths, filter prefixes, OCR, and Spotlight.
extension PanelViewModel {
    var emptyResultMessage: String {
        if similarAnchor != nil {
            return similarStatusMessage ?? L10n.tr("panel.empty.no_results")
        }
        switch QueryParser.parse(query).mode {
        case .terminal(let cmd) where cmd.isEmpty:
            return L10n.tr("panel.empty.terminal")
        case .filtered(let filter, let term) where filter != .appsOnly && filter != .clipboard && term.count < 2:
            return L10n.tr("panel.empty.min_chars")
        case .filtered(let filter, let term) where filter == .clipboard && term.isEmpty:
            return L10n.tr("panel.empty.clipboard_empty")
        default:
            return L10n.tr("panel.empty.no_results")
        }
    }

    func buildEmptyStateItems() -> [SearchItem] {
        var result: [SearchItem] = []
        if let semanticIndexer,
           semanticIndexer.canSearchClipboardImage(),
           ClipboardHistoryStore.hasSafePasteboardImage() {
            result.append(SearchItem(
                id: "sys:clipboard_similar",
                title: L10n.tr("sys.clipboard_similar.title"),
                subtitle: L10n.tr("sys.clipboard_similar.subtitle"),
                category: .quickAction,
                sfSymbol: "sparkles.rectangle.stack",
                score: 980,
                action: .systemCommand("clipboard_similar"),
                matchSource: .quickAction
            ))
        }
        result.append(contentsOf: appScanner.topFrequentApps(limit: 5))
        result.append(contentsOf: recentFiles.recentItems(limit: 6))
        return result
    }

    func scheduleEmptyStateRefresh() {
        emptyRefreshTask?.cancel()
        let generation = searchGeneration
        emptyRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let self, self.searchGeneration == generation else { return }
            guard case .empty = QueryParser.parse(self.query).mode, !self.hasNavigated else { return }
            let refreshed = self.buildEmptyStateItems()
            if refreshed != self.items {
                self.applyItems(refreshed, preserveSelection: false)
            }
        }
    }

    func queryDidChange() {
        if isUpdatingQueryInternally { return }
        if similarAnchor != nil {
            dispatchSimilarSearch(refinement: query)
            return
        }

        searchGeneration &+= 1
        let generation = searchGeneration

        onCancelPendingHide?()
        closeActionPalette()
        spotlightSearch.cancel()
        ocrSearchTask?.cancel()
        ocrSearchTask = nil
        semanticSearchTask?.cancel()
        semanticSearchTask = nil
        emptyRefreshTask?.cancel()
        emptyRefreshTask = nil

        hasNavigated = false
        selectedItemID = nil
        pendingConfirmationID = nil
        if toastStyle == .warning { clearToast() }

        appResults = []
        recentResults = []
        ocrResults = []
        semanticResults = []
        fileResults = []
        isSearchingFiles = false

        let parsed = QueryParser.parse(query)
        switch parsed.mode {
        case .empty:
            activeFilterBadge = nil
            applyItems(buildEmptyStateItems(), preserveSelection: false)

        case .terminal(let cmd):
            activeFilterBadge = L10n.tr("panel.badge.terminal")
            guard !cmd.isEmpty else {
                applyItems([], preserveSelection: false)
                return
            }
            let actions = QuickActionRouter.generate(for: parsed.raw, localHits: [], frecency: frecency)
            applyItems(actions, preserveSelection: false)

        case .path(let rawPath):
            activeFilterBadge = L10n.tr("panel.badge.path")
            let pathItems = PathNavigator.search(rawPath: rawPath, limit: 24)
            applyItems(pathItems, preserveSelection: false)

        case .filtered(let filter, let term):
            activeFilterBadge = filter.badgeTitle
            handleFilteredQuery(filter: filter, term: term, generation: generation)

        case .general(let term):
            activeFilterBadge = nil
            handleGeneralQuery(term: term, generation: generation)
        }
    }

    private func handleFilteredQuery(filter: SearchKindFilter, term: String, generation: UInt64) {
        if filter == .appsOnly {
            let apps = term.isEmpty
                ? appScanner.topFrequentApps(limit: 12)
                : appScanner.search(query: term, limit: 18)
            applyItems(apps, preserveSelection: false)
            return
        }

        if filter == .clipboard {
            var clipItems = clipboardHistory.search(query: term, limit: 24)
            if term.isEmpty,
               let semanticIndexer,
               semanticIndexer.canSearchClipboardImage(),
               ClipboardHistoryStore.hasSafePasteboardImage() {
                let reverseItem = SearchItem(
                    id: "sys:clipboard_similar",
                    title: L10n.tr("sys.clipboard_similar.title"),
                    subtitle: L10n.tr("sys.clipboard_similar.subtitle"),
                    category: .quickAction,
                    sfSymbol: "sparkles.rectangle.stack",
                    score: 990,
                    action: .systemCommand("clipboard_similar"),
                    matchSource: .quickAction
                )
                clipItems.insert(reverseItem, at: 0)
            }
            applyItems(clipItems, preserveSelection: false)
            return
        }

        let expr = SemanticQueryExpression.parse(term)
        let positiveTerm = expr.positiveQuery
        guard positiveTerm.count >= 2 else {
            applyItems([], preserveSelection: false)
            return
        }

        if filter != .contentOnly {
            recentResults = recentFiles.searchInstant(query: positiveTerm, filter: filter, limit: 10)
        }
        rebuildMergedItems(term: term, filter: filter, includeQuickActions: false, preserveSelection: false)

        if filter == .imagesOnly || filter == .pdfOnly || filter == .contentOnly {
            dispatchOCR(term: positiveTerm, filter: filter, includeQuickActions: false, generation: generation)
        }
        if filter == .imagesOnly || filter == .pdfOnly || filter == .filesOnly || filter == .contentOnly {
            dispatchSemantic(term: term, filter: filter, includeQuickActions: false, generation: generation)
        }

        isSearchingFiles = true
        dispatchSpotlight(term: positiveTerm, filter: filter, includeQuickActions: false, generation: generation)
    }

    private func handleGeneralQuery(term: String, generation: UInt64) {
        let expr = SemanticQueryExpression.parse(term)
        let positiveTerm = expr.positiveQuery

        appResults = appScanner.search(query: positiveTerm, limit: 10)
        recentResults = recentFiles.searchInstant(query: positiveTerm, filter: nil, limit: 10)
        rebuildMergedItems(term: term, filter: nil, includeQuickActions: true, preserveSelection: false)

        guard positiveTerm.count >= 2 else { return }

        dispatchOCR(term: positiveTerm, filter: nil, includeQuickActions: true, generation: generation)
        dispatchSemantic(term: term, filter: nil, includeQuickActions: true, generation: generation)
        isSearchingFiles = true
        dispatchSpotlight(term: positiveTerm, filter: nil, includeQuickActions: true, generation: generation)
    }

    private func dispatchSemantic(
        term: String,
        filter: SearchKindFilter?,
        includeQuickActions: Bool,
        generation: UInt64
    ) {
        guard let semanticIndexer else { return }
        semanticSearchTask?.cancel()
        semanticSearchTask = Task { [weak self] in
            // Slight debounce so rapid typing does not saturate the local Metal queue on every keystroke.
            try? await Task.sleep(nanoseconds: 75_000_000)
            guard !Task.isCancelled else { return }
            let hits = await semanticIndexer.searchAsync(query: term, filter: filter, limit: 10)
            guard !Task.isCancelled, let self, self.searchGeneration == generation else { return }
            self.semanticResults = hits
            self.rebuildMergedItems(
                term: term,
                filter: filter,
                includeQuickActions: includeQuickActions,
                preserveSelection: true
            )
        }
    }

    private func dispatchOCR(
        term: String,
        filter: SearchKindFilter?,
        includeQuickActions: Bool,
        generation: UInt64
    ) {
        guard let ocrIndexer else { return }
        ocrSearchTask?.cancel()
        ocrSearchTask = Task { [weak self] in
            let hits = await ocrIndexer.searchAsync(query: term, filter: filter, limit: 12)
            guard !Task.isCancelled, let self, self.searchGeneration == generation else { return }
            self.ocrResults = hits
            self.rebuildMergedItems(
                term: term,
                filter: filter,
                includeQuickActions: includeQuickActions,
                preserveSelection: true
            )
        }
    }

    private func dispatchSpotlight(
        term: String,
        filter: SearchKindFilter?,
        includeQuickActions: Bool,
        generation: UInt64
    ) {
        spotlightSearch.searchProgressive(query: term, filter: filter) { [weak self] files, isFinished in
            guard let self, self.searchGeneration == generation else { return }
            self.fileResults = files
            if isFinished {
                self.isSearchingFiles = false
            }
            self.rebuildMergedItems(
                term: term,
                filter: filter,
                includeQuickActions: includeQuickActions,
                preserveSelection: true
            )
        }
    }

    func rebuildMergedItems(
        term: String,
        filter: SearchKindFilter?,
        includeQuickActions: Bool,
        preserveSelection: Bool
    ) {
        let expr = SemanticQueryExpression.parse(term)
        let positiveTerm = expr.positiveQuery
        let filterNegatives: ([SearchItem]) -> [SearchItem] = { list in
            guard expr.hasNegatives else { return list }
            return list.filter { item in
                !expr.matchesNegativeTerm(in: item.title)
                    && !(item.matchedSnippet.map { expr.matchesNegativeTerm(in: $0) } ?? false)
            }
        }

        let filteredRecent = filterNegatives(recentResults)
        let filteredOCR = filterNegatives(ocrResults)
        let filteredFiles = filterNegatives(fileResults)
        let combinedVisualAndOCR = filteredOCR + semanticResults

        let quick: [SearchItem]
        if includeQuickActions {
            let mergedFiles = ResultRanker.mergeDeduplicatingFiles(
                recent: filteredRecent,
                ocr: combinedVisualAndOCR,
                files: filteredFiles
            )
            quick = QuickActionRouter.generate(
                for: query,
                localHits: appResults + mergedFiles,
                frecency: frecency
            )
        } else {
            quick = []
        }

        let ranked = ResultRanker.mergeAndRank(
            query: positiveTerm,
            quickActions: quick,
            apps: appResults,
            recentFiles: filteredRecent,
            ocrFiles: combinedVisualAndOCR,
            spotlightFiles: filteredFiles,
            filter: filter,
            limit: 18
        )
        applyItems(ranked, preserveSelection: preserveSelection)
    }
}
