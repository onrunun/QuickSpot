import AppKit
import Foundation
import QuickSpotCore

/// Isolates "Find Similar" anchor lifecycle, clipboard reverse-image lookup, cross-modal scope switching, and hybrid refinement.
extension PanelViewModel {
    func similarityKind(for item: SearchItem?) -> SimilarityTargetKind? {
        guard let item,
              let url = item.previewURL,
              url.isFileURL,
              let semanticIndexer else {
            return nil
        }
        return semanticIndexer.similarityTargetKind(for: url)
    }

    func findSimilarForSelected() {
        guard let item = selectedItem, let url = item.previewURL, url.isFileURL else { return }
        findSimilar(for: item, url: url)
    }

    func findSimilar(for item: SearchItem, url: URL) {
        guard let semanticIndexer else { return }
        guard let kind = semanticIndexer.similarityTargetKind(for: url) else {
            if VisionTextExtractor.isSupportedImage(url) || url.pathExtension.lowercased() == "pdf" {
                showToast(L10n.tr("panel.toast.similar_unavailable"), style: .warning, duration: 3.0)
            }
            return
        }

        onCancelPendingHide?()
        closeActionPalette()

        if similarAnchor == nil {
            previousQueryBeforeSimilar = query
        }
        clipboardAnchorImage = nil
        cachedClipboardVector = nil
        similarAnchor = SimilarityAnchor(url: url, title: item.title, kind: kind)
        similarScope = SimilaritySearchScope.defaultScope(for: kind)
        canSwitchSimilarScope = semanticIndexer.hasBothModalitiesIndexed()
        similarStatusMessage = nil
        activeFilterBadge = nil

        if !query.isEmpty {
            isUpdatingQueryInternally = true
            query = ""
            isUpdatingQueryInternally = false
        }

        dispatchSimilarSearch(refinement: nil)
        requestSearchFocusCaretAtEnd()
    }

    func findSimilarFromClipboardImage() {
        guard let semanticIndexer else { return }
        guard semanticIndexer.canSearchClipboardImage() else {
            showToast(L10n.tr("panel.toast.similar_unavailable"), style: .warning, duration: 3.0)
            return
        }
        guard let clip = ClipboardHistoryStore.readSafePasteboardImage() else {
            showToast(L10n.tr("panel.toast.no_clipboard_image"), style: .warning, duration: 2.8)
            return
        }

        onCancelPendingHide?()
        closeActionPalette()

        if similarAnchor == nil {
            previousQueryBeforeSimilar = query
        }
        clipboardAnchorImage = clip.image
        cachedClipboardVector = nil
        similarAnchor = SimilarityAnchor(title: L10n.tr("panel.similar.clipboard_title"))
        similarScope = semanticIndexer.hasBothModalitiesIndexed() ? .images : .all
        canSwitchSimilarScope = semanticIndexer.hasBothModalitiesIndexed()
        similarStatusMessage = nil
        activeFilterBadge = nil

        if !query.isEmpty {
            isUpdatingQueryInternally = true
            query = ""
            isUpdatingQueryInternally = false
        }

        dispatchClipboardImageSimilarSearch(cgImage: clip.cgImage, refinement: nil)
        requestSearchFocusCaretAtEnd()
    }

    func setSimilarScope(_ scope: SimilaritySearchScope) {
        guard similarAnchor != nil, similarScope != scope else { return }
        similarScope = scope
        dispatchSimilarSearch(refinement: query)
    }

    func exitSimilarMode(restorePreviousQuery: Bool = true) {
        guard similarAnchor != nil else { return }
        onCancelPendingHide?()
        closeActionPalette()
        semanticSearchTask?.cancel()
        semanticSearchTask = nil
        similarAnchor = nil
        similarStatusMessage = nil
        canSwitchSimilarScope = false
        clipboardAnchorImage = nil
        cachedClipboardVector = nil
        isSearchingFiles = false

        let restored = restorePreviousQuery ? (previousQueryBeforeSimilar ?? "") : ""
        previousQueryBeforeSimilar = nil

        if query != restored {
            query = restored
        } else {
            queryDidChange()
        }
        requestSearchFocusCaretAtEnd()
    }

    func clearQueryAndSimilar() {
        onCancelPendingHide?()
        pendingConfirmationID = nil
        if toastStyle == .warning { clearToast() }
        if similarAnchor != nil {
            exitSimilarMode(restorePreviousQuery: false)
        } else {
            query = ""
            requestSearchFocusCaretAtEnd()
        }
    }

    func dispatchSimilarSearch(refinement: String?) {
        guard let anchor = similarAnchor, let semanticIndexer else { return }

        if anchor.isClipboardImage {
            if let vector = cachedClipboardVector {
                dispatchVectorSimilarSearch(vector: vector, scope: similarScope, refinement: refinement)
            } else if let nsImage = clipboardAnchorImage,
                      let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                dispatchClipboardImageSimilarSearch(cgImage: cgImage, refinement: refinement)
            }
            return
        }

        guard let url = anchor.url else { return }
        let generation = beginSimilarSearchGeneration()
        let scope = similarScope
        let effectiveRefinement = normalizeRefinement(refinement)

        semanticSearchTask = Task { [weak self] in
            if effectiveRefinement != nil {
                try? await Task.sleep(nanoseconds: 110_000_000)
                guard !Task.isCancelled else { return }
            }

            let result = await semanticIndexer.findSimilarAsync(
                to: url,
                kind: anchor.kind,
                scope: scope,
                refinementQuery: effectiveRefinement,
                limit: 18
            )
            guard !Task.isCancelled, let self, self.searchGeneration == generation else { return }
            self.applySimilarityResult(result, scope: scope)
        }
    }

    private func dispatchClipboardImageSimilarSearch(cgImage: CGImage, refinement: String?) {
        guard let semanticIndexer else { return }
        let generation = beginSimilarSearchGeneration()
        let scope = similarScope
        let effectiveRefinement = normalizeRefinement(refinement)

        semanticSearchTask = Task { [weak self] in
            let embedded = await semanticIndexer.embedClipboardImageAsync(cgImage)
            guard !Task.isCancelled, let self, self.searchGeneration == generation else { return }

            guard let vector = embedded.vector, embedded.status == .ready else {
                self.applySimilarityResult(SimilaritySearchResult(items: [], status: embedded.status), scope: scope)
                return
            }
            self.cachedClipboardVector = vector

            let result = await semanticIndexer.findSimilarByVectorAsync(
                vector,
                sourceKind: .image,
                excludePath: nil,
                scope: scope,
                refinementQuery: effectiveRefinement,
                limit: 18
            )
            guard !Task.isCancelled, self.searchGeneration == generation else { return }
            self.applySimilarityResult(result, scope: scope)
        }
    }

    private func dispatchVectorSimilarSearch(
        vector: [Float],
        scope: SimilaritySearchScope,
        refinement: String?
    ) {
        guard let semanticIndexer else { return }
        let generation = beginSimilarSearchGeneration()
        let effectiveRefinement = normalizeRefinement(refinement)

        semanticSearchTask = Task { [weak self] in
            if effectiveRefinement != nil {
                try? await Task.sleep(nanoseconds: 110_000_000)
                guard !Task.isCancelled else { return }
            }

            let result = await semanticIndexer.findSimilarByVectorAsync(
                vector,
                sourceKind: .image,
                excludePath: nil,
                scope: scope,
                refinementQuery: effectiveRefinement,
                limit: 18
            )
            guard !Task.isCancelled, let self, self.searchGeneration == generation else { return }
            self.applySimilarityResult(result, scope: scope)
        }
    }

    private func beginSimilarSearchGeneration() -> UInt64 {
        searchGeneration &+= 1
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

        isSearchingFiles = true
        similarStatusMessage = nil
        return searchGeneration
    }

    private func normalizeRefinement(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.count >= 2 ? trimmed : nil
    }

    private func applySimilarityResult(_ result: SimilaritySearchResult, scope: SimilaritySearchScope) {
        isSearchingFiles = false
        switch result.status {
        case .ready:
            similarStatusMessage = nil
            applyItems(result.items, preserveSelection: false)
        case .empty:
            similarStatusMessage = (scope == .documents)
                ? L10n.tr("panel.similar.empty_docs")
                : L10n.tr("panel.similar.empty_images")
            applyItems([], preserveSelection: false)
        case .modelsMissing:
            similarStatusMessage = L10n.tr("panel.similar.models_missing")
            applyItems([], preserveSelection: false)
        case .semanticDisabled:
            similarStatusMessage = L10n.tr("settings.semantic.disabled")
            applyItems([], preserveSelection: false)
        case .noIndexedCorpus:
            similarStatusMessage = L10n.tr("panel.similar.no_corpus")
            applyItems([], preserveSelection: false)
        case .unreadableSource:
            similarStatusMessage = L10n.tr("ocr.error.unreadable")
            applyItems([], preserveSelection: false)
        }
    }
}
