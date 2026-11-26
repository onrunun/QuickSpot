import Foundation

/// Pure, Sendable ranking, deduplication, dual-signal fusion, and diversity-slot engine.
public enum ResultRanker: Sendable {
    private enum SignalKind {
        case name
        case content
    }

    private enum DiversityBucket: CaseIterable {
        case app
        case fileOrFolder
        case ocr
    }

    private struct MergedEntry {
        var bestNameHit: SearchItem?
        var bestContentHit: SearchItem?
        var isFolder: Bool
        var preferredSnippet: String?

        mutating func absorb(_ item: SearchItem, kind: SignalKind) {
            if item.category == .folder {
                isFolder = true
            }
            if let snippet = item.matchedSnippet, !snippet.isEmpty {
                if preferredSnippet == nil || kind == .content {
                    preferredSnippet = snippet
                }
            }
            switch kind {
            case .name:
                if let current = bestNameHit {
                    if item.score > current.score
                        || (item.score == current.score && item.matchSource == .name && current.matchSource != .name) {
                        bestNameHit = item
                    }
                } else {
                    bestNameHit = item
                }
            case .content:
                if let current = bestContentHit {
                    if item.score > current.score
                        || (item.score == current.score && item.matchSource == .ocrContent && current.matchSource != .ocrContent) {
                        bestContentHit = item
                    }
                } else {
                    bestContentHit = item
                }
            }
        }

        func materialized() -> SearchItem {
            if let nameHit = bestNameHit, let contentHit = bestContentHit {
                let peak = max(nameHit.score, contentHit.score)
                let fusedScore = max(peak, min(peak + 70, 990))
                let category: SearchCategory = isFolder ? .folder : nameHit.category
                return SearchItem(
                    id: nameHit.id,
                    title: nameHit.title,
                    subtitle: nameHit.subtitle,
                    category: category,
                    iconPath: nameHit.iconPath ?? contentHit.iconPath,
                    sfSymbol: nameHit.sfSymbol ?? contentHit.sfSymbol,
                    score: fusedScore,
                    action: nameHit.action,
                    previewURL: nameHit.previewURL ?? contentHit.previewURL,
                    matchedSnippet: preferredSnippet ?? contentHit.matchedSnippet ?? nameHit.matchedSnippet,
                    matchSource: nameHit.matchSource,
                    requiresConfirmation: nameHit.requiresConfirmation || contentHit.requiresConfirmation
                )
            }

            let winner = bestNameHit ?? bestContentHit!
            let category: SearchCategory = isFolder ? .folder : winner.category
            if category == winner.category && preferredSnippet == winner.matchedSnippet {
                return winner
            }
            return SearchItem(
                id: winner.id,
                title: winner.title,
                subtitle: winner.subtitle,
                category: category,
                iconPath: winner.iconPath,
                sfSymbol: winner.sfSymbol,
                score: winner.score,
                action: winner.action,
                previewURL: winner.previewURL,
                matchedSnippet: preferredSnippet ?? winner.matchedSnippet,
                matchSource: winner.matchSource,
                requiresConfirmation: winner.requiresConfirmation
            )
        }
    }

    /// Deduplicates recent, OCR, and Spotlight file hits by standardized path, fusing name + content hits.
    public static func mergeDeduplicatingFiles(
        recent: [SearchItem] = [],
        ocr: [SearchItem],
        files: [SearchItem]
    ) -> [SearchItem] {
        var byKey: [String: MergedEntry] = [:]
        var keyOrder: [String] = []

        func ingest(_ item: SearchItem, defaultKind: SignalKind) {
            let key = canonicalKey(for: item)
            let kind: SignalKind
            switch item.matchSource {
            case .ocrContent, .fileContent:
                kind = .content
            case .name, .recent, .path, .quickAction, .clipboard:
                kind = defaultKind
            }

            if byKey[key] == nil {
                keyOrder.append(key)
                byKey[key] = MergedEntry(
                    bestNameHit: nil,
                    bestContentHit: nil,
                    isFolder: false,
                    preferredSnippet: nil
                )
            }
            byKey[key]?.absorb(item, kind: kind)
        }

        for item in files { ingest(item, defaultKind: .name) }
        for item in recent { ingest(item, defaultKind: .name) }
        for item in ocr { ingest(item, defaultKind: .content) }

        let merged = keyOrder.compactMap { byKey[$0]?.materialized() }
        return merged.sorted(by: isRankedBefore)
    }

    /// Merges all result pools with dual-signal fusion and diversity-slot protection for unfiltered searches.
    public static func mergeAndRank(
        query: String,
        quickActions: [SearchItem],
        apps: [SearchItem],
        recentFiles: [SearchItem],
        ocrFiles: [SearchItem],
        spotlightFiles: [SearchItem],
        filter: SearchKindFilter? = nil,
        limit: Int = 18
    ) -> [SearchItem] {
        _ = query
        guard limit > 0 else { return [] }

        let mergedFiles = mergeDeduplicatingFiles(recent: recentFiles, ocr: ocrFiles, files: spotlightFiles)
        var seenKeys = Set<String>()
        var combined: [SearchItem] = []

        for item in quickActions {
            if seenKeys.insert(canonicalKey(for: item)).inserted {
                combined.append(item)
            }
        }
        for item in apps {
            if seenKeys.insert(canonicalKey(for: item)).inserted {
                combined.append(item)
            }
        }
        for item in mergedFiles {
            if seenKeys.insert(canonicalKey(for: item)).inserted {
                combined.append(item)
            }
        }

        let sortedAll = combined.sorted(by: isRankedBefore)
        guard filter == nil, sortedAll.count > limit, limit > 2 else {
            return Array(sortedAll.prefix(limit))
        }

        return applyDiversitySlots(sortedAll: sortedAll, limit: limit)
    }

    private static func applyDiversitySlots(sortedAll: [SearchItem], limit: Int) -> [SearchItem] {
        let presentBuckets = Set(sortedAll.compactMap(diversityBucket(for:)))
        guard presentBuckets.count >= 2 else {
            return Array(sortedAll.prefix(limit))
        }

        var selectedIndices = Set<Int>()
        var bucketCounts: [DiversityBucket: Int] = [:]

        func select(index: Int) {
            guard selectedIndices.insert(index).inserted else { return }
            if let bucket = diversityBucket(for: sortedAll[index]) {
                bucketCounts[bucket, default: 0] += 1
            }
        }

        // 1. Always preserve the absolute Top 2 overall hits.
        let topAnchorCount = min(2, sortedAll.count)
        for idx in 0..<topAnchorCount {
            select(index: idx)
        }

        // 2. Guarantee visible slots per active category via round-robin so no single source starves others.
        let quotas = minimumQuotas(for: limit)
        var bucketQueues: [DiversityBucket: [Int]] = [:]
        for idx in topAnchorCount..<sortedAll.count {
            if let bucket = diversityBucket(for: sortedAll[idx]) {
                bucketQueues[bucket, default: []].append(idx)
            }
        }

        var cursors: [DiversityBucket: Int] = [:]
        let rotationOrder: [DiversityBucket] = [.app, .fileOrFolder, .ocr]
        var madeProgress = true
        while selectedIndices.count < limit && madeProgress {
            madeProgress = false
            for bucket in rotationOrder {
                guard selectedIndices.count < limit else { break }
                let target = quotas[bucket] ?? 0
                guard (bucketCounts[bucket] ?? 0) < target else { continue }
                guard let indices = bucketQueues[bucket] else { continue }
                let cursor = cursors[bucket] ?? 0
                if cursor < indices.count {
                    select(index: indices[cursor])
                    cursors[bucket] = cursor + 1
                    madeProgress = true
                }
            }
        }

        // 3. Fill remaining budget with highest-scoring unselected candidates overall.
        for idx in 0..<sortedAll.count where selectedIndices.count < limit {
            select(index: idx)
        }

        return selectedIndices.sorted().map { sortedAll[$0] }
    }

    private static func minimumQuotas(for limit: Int) -> [DiversityBucket: Int] {
        if limit >= 14 {
            return [.app: 3, .fileOrFolder: 5, .ocr: 3]
        } else if limit >= 8 {
            return [.app: 2, .fileOrFolder: 3, .ocr: 2]
        } else if limit >= 4 {
            return [.app: 1, .fileOrFolder: 2, .ocr: 1]
        } else {
            return [.app: 1, .fileOrFolder: 1, .ocr: 1]
        }
    }

    private static func diversityBucket(for item: SearchItem) -> DiversityBucket? {
        switch item.category {
        case .quickAction:
            return nil
        case .application:
            return .app
        case .folder, .file:
            return item.matchSource == .ocrContent ? .ocr : .fileOrFolder
        }
    }

    private static func canonicalKey(for item: SearchItem) -> String {
        item.previewURL?.standardizedFileURL.path ?? item.id
    }

    private static func categoryTiePriority(_ category: SearchCategory) -> Int {
        switch category {
        case .quickAction: return 0
        case .application: return 1
        case .folder: return 2
        case .file: return 3
        }
    }

    private static func isRankedBefore(_ lhs: SearchItem, _ rhs: SearchItem) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        let lp = categoryTiePriority(lhs.category)
        let rp = categoryTiePriority(rhs.category)
        if lp != rp {
            return lp < rp
        }
        let cmp = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if cmp != .orderedSame {
            return cmp == .orderedAscending
        }
        return lhs.id < rhs.id
    }
}
