import Accelerate
import CoreGraphics
import Foundation
import os

/// Target modality of the anchor item in a "Find Similar" session.
public enum SimilarityTargetKind: String, Equatable, Sendable {
    case image
    case document
}

/// Output corpus scope for "Find Similar" searches, enabling cross-modal Image ↔ PDF jumps.
public enum SimilaritySearchScope: String, CaseIterable, Equatable, Sendable {
    case images
    case documents
    case all

    public static func defaultScope(for kind: SimilarityTargetKind) -> SimilaritySearchScope {
        kind == .image ? .images : .documents
    }
}

/// Active reference item anchored in the launcher search bar during a "Find Similar" session.
public struct SimilarityAnchor: Equatable, Sendable {
    public let id: String
    public let url: URL?
    public let title: String
    public let kind: SimilarityTargetKind
    public let isClipboardImage: Bool

    public init(url: URL, title: String, kind: SimilarityTargetKind) {
        self.id = url.standardizedFileURL.path
        self.url = url
        self.title = title
        self.kind = kind
        self.isClipboardImage = false
    }

    public init(clipboardID: String = UUID().uuidString, title: String) {
        self.id = "clipboard:\(clipboardID)"
        self.url = nil
        self.title = title
        self.kind = .image
        self.isClipboardImage = true
    }
}

/// Structured outcome of a local "Find Similar" query so the UI can explain empty or unavailable states clearly.
public struct SimilaritySearchResult: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case ready
        case semanticDisabled
        case modelsMissing
        case noIndexedCorpus
        case unreadableSource
        case empty
    }

    public let items: [SearchItem]
    public let status: Status

    public init(items: [SearchItem], status: Status) {
        self.items = items
        self.status = status
    }
}

/// Powers sub-millisecond image-to-image, document-to-document, cross-modal (Image ↔ PDF),
/// clipboard reverse-image, and hybrid text-refined similarity search.
final class SemanticSimilarityService: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.quickspot.core", category: "SemanticSimilarityService")

    /// Calibrated same-modality and cross-modality cosine floors for EmbeddingGemma 2.
    static let defaultImageMinSimilarity: Float = 0.65
    static let defaultImageRefinedMinSimilarity: Float = 0.56
    static let defaultDocumentMinSimilarity: Float = 0.68
    static let defaultDocumentRefinedMinSimilarity: Float = 0.62
    static let crossModalMinSimilarity: Float = 0.60
    static let crossModalRefinedMinSimilarity: Float = 0.55
    static let refinementWeight: Float = 0.35
    static let minCorpusSizeForZScore = 20
    static let minZScore: Float = 0.45

    private let store: SemanticVectorStore
    private let documentIndexer: SemanticDocumentIndexer?
    private let engine: SemanticEmbeddingProvider
    private let semanticSettingsStore: SemanticSettingsStore
    private let imageMinSimilarity: Float
    private let documentMinSimilarity: Float

    init(
        store: SemanticVectorStore,
        documentIndexer: SemanticDocumentIndexer?,
        engine: SemanticEmbeddingProvider,
        semanticSettingsStore: SemanticSettingsStore,
        imageMinSimilarity: Float = SemanticSimilarityService.defaultImageMinSimilarity,
        documentMinSimilarity: Float = SemanticSimilarityService.defaultDocumentMinSimilarity
    ) {
        self.store = store
        self.documentIndexer = documentIndexer
        self.engine = engine
        self.semanticSettingsStore = semanticSettingsStore
        self.imageMinSimilarity = imageMinSimilarity
        self.documentMinSimilarity = documentMinSimilarity
    }

    func targetKind(for url: URL) -> SimilarityTargetKind? {
        guard url.isFileURL else { return nil }
        guard semanticSettingsStore.load().isEnabled else { return nil }
        let hasImages = store.count(forModelID: engine.modelIdentifier) > 0
        let hasDocs = (documentIndexer?.documentCount() ?? 0) > 0
        guard hasImages || hasDocs else { return nil }
        if VisionTextExtractor.isSupportedImage(url) {
            return .image
        }
        if url.pathExtension.lowercased() == "pdf" {
            return .document
        }
        return nil
    }

    func canSearchClipboardImage() -> Bool {
        guard semanticSettingsStore.load().isEnabled else { return false }
        let hasCorpus = store.count(forModelID: engine.modelIdentifier) > 0
            || (documentIndexer?.documentCount() ?? 0) > 0
        return hasCorpus
    }

    func hasBothModalitiesIndexed() -> Bool {
        store.count(forModelID: engine.modelIdentifier) > 0
            && (documentIndexer?.documentCount() ?? 0) > 0
    }

    func findSimilar(
        to url: URL,
        kind: SimilarityTargetKind? = nil,
        scope: SimilaritySearchScope? = nil,
        refinementQuery: String? = nil,
        limit: Int = 18
    ) async -> SimilaritySearchResult {
        guard url.isFileURL, limit > 0 else {
            return SimilaritySearchResult(items: [], status: .unreadableSource)
        }
        guard semanticSettingsStore.load().isEnabled else {
            return SimilaritySearchResult(items: [], status: .semanticDisabled)
        }

        let resolvedKind: SimilarityTargetKind
        if let kind {
            resolvedKind = kind
        } else if VisionTextExtractor.isSupportedImage(url) {
            resolvedKind = .image
        } else if url.pathExtension.lowercased() == "pdf" {
            resolvedKind = .document
        } else {
            return SimilaritySearchResult(items: [], status: .unreadableSource)
        }

        let resolvedScope = scope ?? SimilaritySearchScope.defaultScope(for: resolvedKind)
        guard hasCorpus(for: resolvedScope) else {
            return SimilaritySearchResult(items: [], status: .noIndexedCorpus)
        }

        let sourceVector: [Float]
        switch resolvedKind {
        case .image:
            let stdPath = url.standardizedFileURL.path
            if let cached = store.vector(forPath: stdPath, modelID: engine.modelIdentifier, dimension: engine.dimension) {
                sourceVector = cached
            } else {
                let status = await engine.modelStatus()
                guard status.isReady else {
                    return SimilaritySearchResult(items: [], status: .modelsMissing)
                }
                do {
                    let embedded = try await engine.embedImages([url])
                    guard let vec = embedded.first?.vector, !vec.isEmpty else {
                        return SimilaritySearchResult(items: [], status: .unreadableSource)
                    }
                    sourceVector = vec
                } catch is CancellationError {
                    return SimilaritySearchResult(items: [], status: .empty)
                } catch {
                    Self.logger.warning("On-the-fly image similarity embed failed: \(error.localizedDescription, privacy: .public)")
                    return SimilaritySearchResult(items: [], status: .unreadableSource)
                }
            }
        case .document:
            guard let documentIndexer else {
                return SimilaritySearchResult(items: [], status: .noIndexedCorpus)
            }
            let resolved = await documentIndexer.resolveCentroidVector(for: url)
            if resolved.missingModel {
                return SimilaritySearchResult(items: [], status: .modelsMissing)
            }
            guard let vec = resolved.vector, !vec.isEmpty else {
                return SimilaritySearchResult(items: [], status: .unreadableSource)
            }
            sourceVector = vec
        }

        guard !Task.isCancelled else { return SimilaritySearchResult(items: [], status: .empty) }

        return await searchByVector(
            sourceVector,
            sourceKind: resolvedKind,
            excludePath: url.standardizedFileURL.path,
            scope: resolvedScope,
            refinementQuery: refinementQuery,
            limit: limit
        )
    }

    func embedClipboardImage(_ cgImage: CGImage) async -> (vector: [Float]?, status: SimilaritySearchResult.Status) {
        guard semanticSettingsStore.load().isEnabled else {
            return (nil, .semanticDisabled)
        }
        let status = await engine.modelStatus()
        guard status.isReady else {
            return (nil, .modelsMissing)
        }
        do {
            let vector = try await engine.embedImage(cgImage)
            guard !vector.isEmpty else { return (nil, .unreadableSource) }
            return (vector, .ready)
        } catch is CancellationError {
            return (nil, .empty)
        } catch {
            Self.logger.warning("Clipboard image embed failed: \(error.localizedDescription, privacy: .public)")
            return (nil, .unreadableSource)
        }
    }

    func searchByVector(
        _ sourceVector: [Float],
        sourceKind: SimilarityTargetKind,
        excludePath: String?,
        scope: SimilaritySearchScope,
        refinementQuery: String?,
        limit: Int
    ) async -> SimilaritySearchResult {
        guard !sourceVector.isEmpty, limit > 0 else {
            return SimilaritySearchResult(items: [], status: .unreadableSource)
        }
        guard semanticSettingsStore.load().isEnabled else {
            return SimilaritySearchResult(items: [], status: .semanticDisabled)
        }
        guard hasCorpus(for: scope) else {
            return SimilaritySearchResult(items: [], status: .noIndexedCorpus)
        }

        let trimmedRefine = refinementQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parsed = SemanticQueryExpression.parse(trimmedRefine)
        let (queryVectors, negativeVectors, activeRefinement) = await buildQueryVectors(
            sourceVector: sourceVector,
            parsed: parsed
        )
        guard !Task.isCancelled else { return SimilaritySearchResult(items: [], status: .empty) }

        var imageItems: [SearchItem] = []
        var docItems: [SearchItem] = []

        if (scope == .images || scope == .all), store.count(forModelID: engine.modelIdentifier) > 0 {
            let isCrossModal = (sourceKind == .document)
            let floor: Float
            if isCrossModal {
                floor = activeRefinement != nil ? Self.crossModalRefinedMinSimilarity : Self.crossModalMinSimilarity
            } else {
                floor = activeRefinement != nil ? min(imageMinSimilarity, Self.defaultImageRefinedMinSimilarity) : imageMinSimilarity
            }
            let searchResult = store.searchWithStats(
                queryVectors: queryVectors,
                negativeVectors: negativeVectors,
                modelID: engine.modelIdentifier,
                limit: limit * 3,
                minSimilarity: floor,
                excludePath: excludePath,
                applyHubness: isCrossModal
            )
            imageItems = buildSimilarImageItems(
                from: searchResult,
                threshold: floor,
                refinement: activeRefinement,
                parsed: parsed,
                limit: limit
            )
        }

        if (scope == .documents || scope == .all), let documentIndexer, documentIndexer.documentCount() > 0 {
            let isCrossModal = (sourceKind == .image)
            let floor: Float
            if isCrossModal {
                floor = activeRefinement != nil ? Self.crossModalRefinedMinSimilarity : Self.crossModalMinSimilarity
            } else {
                floor = activeRefinement != nil ? min(documentMinSimilarity, Self.defaultDocumentRefinedMinSimilarity) : documentMinSimilarity
            }
            let searchResult = documentIndexer.searchSimilarRaw(
                queryVectors: queryVectors,
                negativeVectors: negativeVectors,
                excludePath: excludePath,
                minSimilarity: floor,
                applyHubness: isCrossModal,
                limit: limit * 2
            )
            docItems = buildSimilarDocumentItems(
                from: searchResult,
                threshold: floor,
                refinement: activeRefinement,
                parsed: parsed,
                limit: limit
            )
        }

        let merged: [SearchItem]
        switch scope {
        case .images: merged = Array(imageItems.prefix(limit))
        case .documents: merged = Array(docItems.prefix(limit))
        case .all: merged = mergeCrossModal(images: imageItems, docs: docItems, limit: limit)
        }
        return SimilaritySearchResult(items: merged, status: merged.isEmpty ? .empty : .ready)
    }

    // MARK: - Private Helpers

    private func hasCorpus(for scope: SimilaritySearchScope) -> Bool {
        let hasImages = store.count(forModelID: engine.modelIdentifier) > 0
        let hasDocs = (documentIndexer?.documentCount() ?? 0) > 0
        switch scope {
        case .images: return hasImages
        case .documents: return hasDocs
        case .all: return hasImages || hasDocs
        }
    }

    private func buildQueryVectors(
        sourceVector: [Float],
        parsed: SemanticQueryExpression
    ) async -> (vectors: [[Float]], negativeVectors: [[Float]], activeRefinement: String?) {
        let posText = parsed.positiveQuery
        let canUseText = await engine.isTextModelReady()
        guard canUseText else { return ([sourceVector], [], nil) }

        var negativeVectors: [[Float]] = []
        for term in parsed.negativeTerms {
            guard !Task.isCancelled else { return ([sourceVector], [], nil) }
            if let negVec = try? await engine.embedQuery(term) {
                negativeVectors.append(negVec)
            }
            if let restored = await TurkishQueryRestorer.restoredVariantAsync(for: term),
               restored.caseInsensitiveCompare(term) != .orderedSame,
               let negRestored = try? await engine.embedQuery(restored) {
                negativeVectors.append(negRestored)
            }
        }

        guard posText.count >= 2 else {
            return ([sourceVector], negativeVectors, nil)
        }

        var textVectors: [[Float]] = []
        do {
            textVectors.append(try await engine.embedQuery(posText))
            if let restored = await TurkishQueryRestorer.restoredVariantAsync(for: posText),
               restored.caseInsensitiveCompare(posText) != .orderedSame,
               !Task.isCancelled {
                textVectors.append(try await engine.embedQuery(restored))
            }
        } catch is CancellationError {
            return ([sourceVector], negativeVectors, nil)
        } catch {
            Self.logger.warning("Similarity refinement embed failed: \(error.localizedDescription, privacy: .public)")
            return ([sourceVector], negativeVectors, nil)
        }

        let blended = textVectors.compactMap {
            Self.blend(primary: sourceVector, secondary: $0, secondaryWeight: Self.refinementWeight)
        }
        guard !blended.isEmpty else { return ([sourceVector], negativeVectors, nil) }
        return (blended, negativeVectors, posText)
    }

    private func buildSimilarImageItems(
        from result: SemanticVectorSearchResult,
        threshold: Float,
        refinement: String?,
        parsed: SemanticQueryExpression,
        limit: Int
    ) -> [SearchItem] {
        let enforceZScore = result.corpusCount >= Self.minCorpusSizeForZScore
        let surviving = result.hits.filter { hit in
            guard hit.similarity >= threshold else { return false }
            if enforceZScore && hit.zScore < Self.minZScore { return false }
            if parsed.matchesNegativeTerm(in: hit.fileName) { return false }
            let url = URL(fileURLWithPath: hit.path)
            return VisionTextExtractor.isSupportedImage(url) && FileManager.default.fileExists(atPath: hit.path)
        }

        let home = NSHomeDirectory()
        let refineTokens = refinement.map { ImageOCRIndexer.normalizedQueryTokens(from: $0) } ?? []

        let scored: [(index: Int, item: SearchItem)] = surviving.enumerated().map { idx, hit in
            let url = URL(fileURLWithPath: hit.path)
            let parent = url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~")
            let pct = Self.formatPercent(hit.similarity)
            let snippet = refinement.map { L10n.format("snippet.similar_refined", pct, $0) }
                ?? L10n.format("snippet.similar_visual_percent", pct)

            let foldedName = VisionTextExtractor.normalizeForSearch(hit.fileName)
            let filenameBonus = refineTokens.contains(where: { foldedName.contains($0) }) ? 25 : 0
            let score = Self.similarityScore(hit.similarity) + filenameBonus

            let item = SearchItem(
                id: "sim:\(hit.path)",
                title: hit.fileName,
                subtitle: parent,
                category: .file,
                iconPath: hit.path,
                score: score,
                action: .openFile(url),
                previewURL: url,
                matchedSnippet: snippet,
                matchSource: .semanticVisual
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

    private func buildSimilarDocumentItems(
        from result: SemanticDocumentSearchResult,
        threshold: Float,
        refinement: String?,
        parsed: SemanticQueryExpression,
        limit: Int
    ) -> [SearchItem] {
        let enforceZScore = result.documentCount >= Self.minCorpusSizeForZScore
        let surviving = result.hits.filter { hit in
            guard hit.similarity >= threshold else { return false }
            if enforceZScore && hit.zScore < Self.minZScore { return false }
            if parsed.matchesNegativeTerm(in: hit.fileName) { return false }
            return FileManager.default.fileExists(atPath: hit.path)
        }

        let home = NSHomeDirectory()
        let refineTokens = refinement.map { ImageOCRIndexer.normalizedQueryTokens(from: $0) } ?? []

        let scored: [(index: Int, item: SearchItem)] = surviving.enumerated().map { idx, hit in
            let url = URL(fileURLWithPath: hit.path)
            let parent = url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~")
            let pct = Self.formatPercent(hit.similarity)
            let snippet: String
            if let refinement {
                snippet = L10n.format("snippet.similar_refined", pct, refinement)
            } else if !hit.excerpt.isEmpty {
                snippet = L10n.format("snippet.similar_doc_excerpt", pct, hit.excerpt)
            } else {
                snippet = L10n.format("snippet.similar_doc_percent", pct)
            }

            let foldedName = VisionTextExtractor.normalizeForSearch(hit.fileName)
            let filenameBonus = refineTokens.contains(where: { foldedName.contains($0) }) ? 25 : 0
            let score = Self.similarityScore(hit.similarity) + filenameBonus

            let item = SearchItem(
                id: "simdoc:\(hit.path)",
                title: hit.fileName,
                subtitle: parent,
                category: .file,
                iconPath: hit.path,
                score: score,
                action: .openFile(url),
                previewURL: url,
                matchedSnippet: snippet,
                matchSource: .semanticText
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

    private func mergeCrossModal(images: [SearchItem], docs: [SearchItem], limit: Int) -> [SearchItem] {
        var byPath: [String: SearchItem] = [:]
        for item in docs + images {
            let key = item.previewURL?.standardizedFileURL.path ?? item.id
            if let existing = byPath[key] {
                if item.score > existing.score { byPath[key] = item }
            } else {
                byPath[key] = item
            }
        }
        return byPath.values.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    static func blend(primary: [Float], secondary: [Float], secondaryWeight: Float) -> [Float]? {
        guard !primary.isEmpty, primary.count == secondary.count else { return nil }
        let w2 = max(0, min(1, secondaryWeight))
        let w1 = 1 - w2
        let count = primary.count
        var out = [Float](repeating: 0, count: count)
        var s1 = w1
        var s2 = w2
        vDSP_vsmul(primary, 1, &s1, &out, 1, vDSP_Length(count))
        vDSP_vsma(secondary, 1, &s2, out, 1, &out, 1, vDSP_Length(count))
        return l2Normalize(out)
    }

    static func meanNormalize(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        let dim = first.count
        var sum = [Float](repeating: 0, count: dim)
        var count = 0
        for vec in vectors where vec.count == dim {
            vDSP_vadd(sum, 1, vec, 1, &sum, 1, vDSP_Length(dim))
            count += 1
        }
        guard count > 0 else { return nil }
        return l2Normalize(sum)
    }

    private static func l2Normalize(_ vector: [Float]) -> [Float]? {
        var normSq: Float = 0
        vDSP_dotpr(vector, 1, vector, 1, &normSq, vDSP_Length(vector.count))
        let norm = sqrt(normSq)
        guard norm > 1e-6 else { return nil }
        var invNorm = 1.0 / norm
        var out = [Float](repeating: 0, count: vector.count)
        vDSP_vsmul(vector, 1, &invNorm, &out, 1, vDSP_Length(vector.count))
        return out
    }

    private static func similarityScore(_ similarity: Float) -> Int {
        let clamped = max(0.0, min(1.0, Double(similarity)))
        return 500 + Int((clamped * 450.0).rounded())
    }

    private static func formatPercent(_ similarity: Float) -> String {
        let clamped = max(0.0, min(1.0, Double(similarity)))
        let rounded = (clamped * 100.0).rounded() / 100.0
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        formatter.locale = L10n.currentLocale
        return formatter.string(from: NSNumber(value: rounded)) ?? "\(Int((rounded * 100).rounded()))%"
    }
}
