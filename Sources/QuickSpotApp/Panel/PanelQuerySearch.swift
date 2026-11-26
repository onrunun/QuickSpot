import Foundation
import QuickSpotCore

/// Isolates QueryParser-driven routing across empty home state, paths, filter prefixes, OCR, and Spotlight.
extension PanelViewModel {
    var emptyResultMessage: String {
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
        appScanner.topFrequentApps(limit: 5) + recentFiles.recentItems(limit: 6)
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
        searchGeneration &+= 1
        let generation = searchGeneration

        onCancelPendingHide?()
        closeActionPalette()
        spotlightSearch.cancel()
        ocrSearchTask?.cancel()
        ocrSearchTask = nil
        emptyRefreshTask?.cancel()
        emptyRefreshTask = nil

        hasNavigated = false
        selectedItemID = nil
        pendingConfirmationID = nil
        if toastStyle == .warning { clearToast() }

        appResults = []
        recentResults = []
        ocrResults = []
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
            applyItems(clipboardHistory.search(query: term, limit: 24), preserveSelection: false)
            return
        }

        guard term.count >= 2 else {
            applyItems([], preserveSelection: false)
            return
        }

        if filter != .contentOnly {
            recentResults = recentFiles.searchInstant(query: term, filter: filter, limit: 10)
        }
        rebuildMergedItems(term: term, filter: filter, includeQuickActions: false, preserveSelection: false)

        if filter == .imagesOnly || filter == .pdfOnly || filter == .contentOnly {
            dispatchOCR(term: term, filter: filter, includeQuickActions: false, generation: generation)
        }

        isSearchingFiles = true
        dispatchSpotlight(term: term, filter: filter, includeQuickActions: false, generation: generation)
    }

    private func handleGeneralQuery(term: String, generation: UInt64) {
        appResults = appScanner.search(query: term, limit: 10)
        recentResults = recentFiles.searchInstant(query: term, filter: nil, limit: 10)
        rebuildMergedItems(term: term, filter: nil, includeQuickActions: true, preserveSelection: false)

        guard term.count >= 2 else { return }

        dispatchOCR(term: term, filter: nil, includeQuickActions: true, generation: generation)
        isSearchingFiles = true
        dispatchSpotlight(term: term, filter: nil, includeQuickActions: true, generation: generation)
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
        let quick: [SearchItem]
        if includeQuickActions {
            let mergedFiles = ResultRanker.mergeDeduplicatingFiles(
                recent: recentResults,
                ocr: ocrResults,
                files: fileResults
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
            query: term,
            quickActions: quick,
            apps: appResults,
            recentFiles: recentResults,
            ocrFiles: ocrResults,
            spotlightFiles: fileResults,
            filter: filter,
            limit: 18
        )
        applyItems(ranked, preserveSelection: preserveSelection)
    }
}
