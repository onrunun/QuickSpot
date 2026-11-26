import Foundation
import os

/// Indexes extracted PDF and OCR document passages using EmbeddingGemma 2's 310 MB text encoder (no `mmproj` required)
/// and answers semantic document queries by reusing already-computed query vectors.
public final class SemanticDocumentIndexer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.quickspot.core", category: "SemanticDocumentIndexer")
    private static let progressEmitInterval: TimeInterval = 0.2

    /// Empirical EmbeddingGemma 2 text↔text cosine cutoffs calibrated on real multilingual PDFs + negative controls.
    /// Text↔text baseline noise sits around ~0.60–0.667; genuine semantic matches jump to ~0.68–0.85+.
    public static let defaultGeneralMinSimilarity: Float = 0.695
    public static let defaultFilteredMinSimilarity: Float = 0.675
    public static let relativeMarginFromTop: Float = 0.045
    public static let minCorpusSizeForZScore = 20
    public static let generalMinZScore: Float = 2.0
    public static let filteredMinZScore: Float = 1.4

    private let documentStore: SemanticDocumentStore
    private let ocrStore: ImageOCRStore
    private let engine: SemanticEmbeddingProvider
    private let pacer: IndexingPacer
    private let generalMinSimilarity: Float
    private let filteredMinSimilarity: Float

    public init(
        documentStore: SemanticDocumentStore = SemanticDocumentStore(),
        ocrStore: ImageOCRStore = ImageOCRStore(),
        engine: SemanticEmbeddingProvider,
        pacer: IndexingPacer = IndexingPacer.live(),
        generalMinSimilarity: Float = SemanticDocumentIndexer.defaultGeneralMinSimilarity,
        filteredMinSimilarity: Float = SemanticDocumentIndexer.defaultFilteredMinSimilarity
    ) {
        self.documentStore = documentStore
        self.ocrStore = ocrStore
        self.engine = engine
        self.pacer = pacer
        self.generalMinSimilarity = generalMinSimilarity
        self.filteredMinSimilarity = filteredMinSimilarity
    }

    public func documentCount() -> Int {
        documentStore.documentCount(forModelID: engine.modelIdentifier)
    }

    public func pruneFolder(_ folderPath: String) {
        documentStore.deleteUnderFolder(folderPath)
    }

    public func clearAll() {
        documentStore.clearAll()
    }

    func removePaths(_ paths: [String]) {
        documentStore.delete(paths: paths)
    }

    /// Reconciles and embeds all text-bearing OCR/PDF documents currently stored in `ImageOCRStore`.
    public func reconcileAll(
        force: Bool,
        blockerProvider: @Sendable () -> String?,
        isEnabled: @Sendable () -> Bool,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async {
        guard isEnabled() else { return }
        guard await engine.isTextModelReady() else { return }

        let docs = ocrStore.textDocuments()
        guard !Task.isCancelled else { return }
        documentStore.deleteMissing(keeping: Set(docs.map(\.path)))

        let states = documentStore.existingStates()
        let activeModelID = engine.modelIdentifier
        let pending = docs.filter { Self.needsEmbedding(doc: $0, existing: states[$0.path], activeModelID: activeModelID) }
        await embedDocuments(
            pending,
            force: force,
            blockerProvider: blockerProvider,
            isEnabled: isEnabled,
            onProgress: onProgress
        )
    }

    /// Incrementally updates or deletes semantic document embeddings for a small set of changed paths.
    public func reconcileIncremental(
        paths: [String],
        blockerProvider: @Sendable () -> String?,
        isEnabled: @Sendable () -> Bool
    ) async {
        let unique = Array(Set(paths.map { ($0 as NSString).standardizingPath }.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return }

        let ocrDocs = ocrStore.textDocuments(forPaths: unique)
        let ocrByPath = Dictionary(uniqueKeysWithValues: ocrDocs.map { ($0.path, $0) })
        let toDelete = unique.filter { ocrByPath[$0] == nil }
        if !toDelete.isEmpty {
            documentStore.delete(paths: toDelete)
        }
        guard !ocrDocs.isEmpty, isEnabled(), await engine.isTextModelReady() else { return }
        if blockerProvider() != nil { return }

        let states = documentStore.existingStates()
        let activeModelID = engine.modelIdentifier
        let pending = ocrDocs.filter { Self.needsEmbedding(doc: $0, existing: states[$0.path], activeModelID: activeModelID) }
        await embedDocuments(pending, force: false, blockerProvider: blockerProvider, isEnabled: isEnabled)
    }

    /// Searches stored PDF/OCR chunk embeddings using precomputed query vector(s) and optional negative vectors (zero extra GPU forward passes).
    public func search(
        queryVectors: [[Float]],
        negativeVectors: [[Float]] = [],
        query: String,
        filter: SearchKindFilter?,
        limit: Int
    ) -> [SearchItem] {
        guard !queryVectors.isEmpty, limit > 0 else { return [] }
        guard documentStore.documentCount(forModelID: engine.modelIdentifier) > 0 else { return [] }

        let kind: OCRDocumentKind?
        switch filter {
        case .pdfOnly: kind = .pdf
        case .imagesOnly: kind = .image
        case .filesOnly, .contentOnly, nil: kind = nil
        case .foldersOnly, .appsOnly, .clipboard: return []
        }

        let isFocusedFilter = (filter == .pdfOnly || filter == .contentOnly || filter == .imagesOnly)
        let threshold = isFocusedFilter ? filteredMinSimilarity : generalMinSimilarity
        let minZ = isFocusedFilter ? Self.filteredMinZScore : Self.generalMinZScore
        let result = documentStore.searchWithStats(
            queryVectors: queryVectors,
            negativeVectors: negativeVectors,
            modelID: engine.modelIdentifier,
            kind: kind,
            limit: limit * 2,
            minSimilarity: threshold
        )
        return SemanticDocumentScorer.buildItems(
            from: result,
            query: query,
            threshold: threshold,
            minZScore: minZ,
            relativeMargin: Self.relativeMarginFromTop,
            minCorpusForZScore: Self.minCorpusSizeForZScore,
            limit: limit
        )
    }

    /// Resolves a stored or on-the-fly L2-normalized document centroid vector for "Find Similar" queries.
    func resolveCentroidVector(for url: URL) async -> (vector: [Float]?, missingModel: Bool) {
        let stdPath = url.standardizedFileURL.path
        if let cached = documentStore.centroidVector(
            forPath: stdPath,
            modelID: engine.modelIdentifier,
            dimension: engine.dimension
        ) {
            return (cached, false)
        }

        guard await engine.isTextModelReady() else {
            return (nil, true)
        }

        let rawText: String
        if let stored = ocrStore.rawText(forPath: stdPath), !stored.isEmpty {
            rawText = stored
        } else if url.pathExtension.lowercased() == "pdf" {
            rawText = await Task.detached(priority: .userInitiated) {
                PDFTextExtractor.extractText(from: url, maxPages: 12)
            }.value
        } else {
            return (nil, false)
        }

        let chunks = Array(SemanticDocumentChunker.chunk(fileName: url.lastPathComponent, rawText: rawText).prefix(6))
        guard !chunks.isEmpty else { return (nil, false) }

        do {
            let vectors = try await engine.embedDocuments(chunks.map(\.embedInput))
            return (SemanticSimilarityService.meanNormalize(vectors), false)
        } catch is CancellationError {
            return (nil, false)
        } catch {
            Self.logger.warning("On-the-fly document similarity embed failed: \(error.localizedDescription, privacy: .public)")
            return (nil, false)
        }
    }

    /// Runs document chunk similarity search excluding the anchor path and returning raw hits for similarity ranking.
    func searchSimilarRaw(
        queryVectors: [[Float]],
        negativeVectors: [[Float]] = [],
        excludePath: String?,
        minSimilarity: Float,
        applyHubness: Bool = false,
        limit: Int
    ) -> SemanticDocumentSearchResult {
        documentStore.searchWithStats(
            queryVectors: queryVectors,
            negativeVectors: negativeVectors,
            modelID: engine.modelIdentifier,
            kind: nil,
            limit: limit,
            minSimilarity: minSimilarity,
            excludePath: excludePath,
            applyHubness: applyHubness
        )
    }

    private func embedDocuments(
        _ pending: [OCRTextDocument],
        force: Bool,
        blockerProvider: @Sendable () -> String?,
        isEnabled: @Sendable () -> Bool,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async {
        guard !pending.isEmpty else { return }
        let activeModelID = engine.modelIdentifier
        let total = pending.count
        var lastEmit = Date.distantPast
        onProgress?(0, total)

        for (idx, doc) in pending.enumerated() {
            await pacer.waitBeforeWork()
            if Task.isCancelled || !isEnabled() { return }
            if !force && blockerProvider() != nil { return }

            var lastBatchElapsed: TimeInterval = 0
            var didRunGPUWork = false
            let chunks = SemanticDocumentChunker.chunk(fileName: doc.name, rawText: doc.rawText)
            if chunks.isEmpty {
                documentStore.delete(paths: [doc.path])
            } else {
                var embeddedPairs: [(chunk: SemanticTextChunk, vector: [Float])] = []
                embeddedPairs.reserveCapacity(chunks.count)
                var failed = false

                var offset = 0
                while offset < chunks.count {
                    await pacer.waitBeforeWork()
                    if Task.isCancelled || !isEnabled() { return }
                    if !force && blockerProvider() != nil { return }
                    let batchSize = max(1, pacer.batchSize(for: .semanticDocument))
                    let end = min(offset + batchSize, chunks.count)
                    let slice = Array(chunks[offset..<end])
                    let started = ProcessInfo.processInfo.systemUptime
                    do {
                        let vectors = try await engine.embedDocuments(slice.map(\.embedInput))
                        guard vectors.count == slice.count else {
                            failed = true
                            break
                        }
                        for (chunk, vec) in zip(slice, vectors) {
                            embeddedPairs.append((chunk, vec))
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        Self.logger.warning("Semantic document embed failed: \(error.localizedDescription, privacy: .public)")
                        failed = true
                        break
                    }
                    lastBatchElapsed = ProcessInfo.processInfo.systemUptime - started
                    didRunGPUWork = true
                    offset = end
                    if offset < chunks.count {
                        await pacer.cooldownAfterWork(for: .semanticDocument, workDuration: lastBatchElapsed, force: force)
                    }
                }

                if failed || embeddedPairs.isEmpty {
                    documentStore.recordFailure(path: doc.path, mtime: doc.mtime, size: doc.size, modelID: activeModelID)
                } else {
                    documentStore.upsertDocumentChunks(
                        path: doc.path,
                        name: doc.name,
                        kind: doc.kind,
                        mtime: doc.mtime,
                        size: doc.size,
                        modelID: activeModelID,
                        chunks: embeddedPairs
                    )
                }
            }

            let done = idx + 1
            let now = Date()
            if done == total || now.timeIntervalSince(lastEmit) >= Self.progressEmitInterval {
                lastEmit = now
                onProgress?(done, total)
            }
            if done < total && didRunGPUWork {
                await pacer.cooldownAfterWork(for: .semanticDocument, workDuration: lastBatchElapsed, force: force)
            } else {
                await Task.yield()
            }
        }
    }

    private static func needsEmbedding(
        doc: OCRTextDocument,
        existing: SemanticStoreEntry?,
        activeModelID: String
    ) -> Bool {
        guard let prev = existing else { return true }
        if prev.modelID != activeModelID { return true }
        if abs(prev.mtime - doc.mtime) > 0.001 || prev.size != doc.size { return true }
        if prev.status == SemanticDocumentStore.statusFailed {
            return prev.retryCount < SemanticDocumentStore.maxFailureRetries
        }
        return false
    }
}
