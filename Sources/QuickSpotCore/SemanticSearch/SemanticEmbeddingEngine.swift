import CoreGraphics
import Foundation
#if arch(arm64)
import GemmaEmbed
#endif
import ImageIO
import os

/// Errors raised when local EmbeddingGemma 2 weights are missing, hardware is unsupported, or input is invalid.
public enum SemanticEngineError: Error, Equatable, LocalizedError, Sendable {
    case modelsMissing([String])
    case emptyQuery
    case unsupportedHardware

    public var errorDescription: String? {
        switch self {
        case .modelsMissing(let files):
            return L10n.format("semantic.error.models_missing", files.joined(separator: ", "))
        case .emptyQuery:
            return L10n.tr("semantic.error.empty_query")
        case .unsupportedHardware:
            return L10n.tr("semantic.error.unsupported_hardware")
        }
    }
}

/// Abstraction over EmbeddingGemma 2 inference so unit tests can inject deterministic mock providers.
public protocol SemanticEmbeddingProvider: Sendable {
    var modelIdentifier: String { get }
    var dimension: Int { get }
    func modelStatus() async -> SemanticModelStatus
    func isTextModelReady() async -> Bool
    func embedQuery(_ text: String) async throws -> [Float]
    func embedDocuments(_ texts: [String]) async throws -> [[Float]]
    func embedImages(_ urls: [URL]) async throws -> [(url: URL, vector: [Float])]
    func embedImage(_ cgImage: CGImage) async throws -> [Float]
    func releaseImageEncoder() async
    func unloadAll() async
}

public extension SemanticEmbeddingProvider {
    func isTextModelReady() async -> Bool {
        await modelStatus().isReady
    }

    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        []
    }

    func embedImage(_ cgImage: CGImage) async throws -> [Float] {
        []
    }
}

/// Runs Google's EmbeddingGemma 2 locally on Apple Silicon Metal via GemmaEmbed with lazy load, coalesced loading, and idle unload.
public actor SemanticEmbeddingEngine: SemanticEmbeddingProvider {
    private static let logger = Logger(subsystem: "com.quickspot.core", category: "SemanticEmbeddingEngine")
    private static let maxCachedQueries = 64

    public nonisolated let modelIdentifier: String = SemanticModelLocator.modelIdentifier
    public nonisolated let dimension: Int = SemanticModelLocator.embeddingDimension

    private let settingsStore: SemanticSettingsStore
    private let overrideDirectory: URL?
    private let idleUnloadSeconds: TimeInterval

    #if arch(arm64)
    private var loadedModel: EmbeddingModel?
    private var inFlightLoad: (task: Task<EmbeddingModel, Error>, dirPath: String, includesVision: Bool, epoch: UInt64)?
    #endif
    private var loadedWithVision = false
    private var loadedDirectoryPath: String?
    private var loadEpoch: UInt64 = 0
    private var idleUnloadTask: Task<Void, Never>?

    private var queryCache: [String: [Float]] = [:]
    private var queryCacheOrder: [String] = []

    public init(
        settingsStore: SemanticSettingsStore = SemanticSettingsStore(),
        overrideDirectory: URL? = nil,
        idleUnloadSeconds: TimeInterval = 300
    ) {
        self.settingsStore = settingsStore
        self.overrideDirectory = overrideDirectory
        self.idleUnloadSeconds = idleUnloadSeconds
    }

    public func modelStatus() async -> SemanticModelStatus {
        if let overrideDirectory {
            return SemanticModelLocator.resolve(in: overrideDirectory)
        }
        return SemanticModelLocator.resolve(customDirectory: settingsStore.load().customModelsDirectory)
    }

    public func isTextModelReady() async -> Bool {
        guard SemanticModelLocator.isHardwareSupported else { return false }
        if let overrideDirectory {
            return SemanticModelLocator.resolveTextModelURL(in: overrideDirectory) != nil
        }
        return SemanticModelLocator.resolveTextModelURL(customDirectory: settingsStore.load().customModelsDirectory) != nil
    }

    public func embedQuery(_ text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SemanticEngineError.emptyQuery }

        let cacheKey = trimmed.lowercased()
        if let cached = queryCache[cacheKey] {
            scheduleIdleUnload()
            return cached
        }

        #if arch(arm64)
        let model = try await ensureModelLoaded(needsVision: false)
        let options = EmbedOptions(
            task: .query,
            maxTokens: 256,
            dimensions: dimension,
            normalise: true
        )
        let embedding = try await model.embed(trimmed, options: options)
        cacheQueryVector(embedding.vector, forKey: cacheKey)
        scheduleIdleUnload()
        return embedding.vector
        #else
        throw SemanticEngineError.unsupportedHardware
        #endif
    }

    public func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        #if arch(arm64)
        let model = try await ensureModelLoaded(needsVision: false)
        let options = EmbedOptions(
            task: .document,
            maxTokens: 512,
            dimensions: dimension,
            normalise: true
        )
        do {
            let embeddings = try await model.embed(texts, options: options)
            scheduleIdleUnload()
            return embeddings.map(\.vector)
        } catch is CancellationError {
            throw CancellationError()
        } catch GemmaEmbedError.cancelled {
            throw CancellationError()
        }
        #else
        throw SemanticEngineError.unsupportedHardware
        #endif
    }

    public func embedImages(_ urls: [URL]) async throws -> [(url: URL, vector: [Float])] {
        guard !urls.isEmpty else { return [] }
        #if arch(arm64)
        let model = try await ensureModelLoaded(needsVision: true)
        let options = ImageEmbedOptions(
            dimensions: dimension,
            normalise: true,
            maxImageTokens: SemanticModelLocator.maxImageTokens
        )

        var results: [(url: URL, vector: [Float])] = []
        results.reserveCapacity(urls.count)

        do {
            let embeddings = try await model.embed(images: urls.map { .url($0) }, options: options)
            for (url, emb) in zip(urls, embeddings) {
                results.append((url: url, vector: emb.vector))
            }
            scheduleIdleUnload()
            return results
        } catch is CancellationError {
            throw CancellationError()
        } catch GemmaEmbedError.cancelled {
            throw CancellationError()
        } catch {
            // Fall back to per-image embedding with CGImage decoding so one unreadable file never aborts a batch.
            for url in urls {
                try Task.checkCancellation()
                if let vector = await embedSingleImageWithFallback(url: url, model: model, options: options) {
                    results.append((url: url, vector: vector))
                }
            }
            scheduleIdleUnload()
            return results
        }
        #else
        throw SemanticEngineError.unsupportedHardware
        #endif
    }

    /// Embeds an in-memory `CGImage` (e.g. from macOS pasteboard) directly on Metal without writing any temporary file to disk.
    public func embedImage(_ cgImage: CGImage) async throws -> [Float] {
        #if arch(arm64)
        let model = try await ensureModelLoaded(needsVision: true)
        let options = ImageEmbedOptions(
            dimensions: dimension,
            normalise: true,
            maxImageTokens: SemanticModelLocator.maxImageTokens
        )
        do {
            let embedding = try await model.embed(image: .cgImage(cgImage), options: options)
            scheduleIdleUnload()
            return embedding.vector
        } catch is CancellationError {
            throw CancellationError()
        } catch GemmaEmbedError.cancelled {
            throw CancellationError()
        }
        #else
        throw SemanticEngineError.unsupportedHardware
        #endif
    }

    public func releaseImageEncoder() async {
        #if arch(arm64)
        guard loadedWithVision || (inFlightLoad?.includesVision == true) else { return }
        #else
        guard loadedWithVision else { return }
        #endif
        invalidateLoadedState()
    }

    public func unloadAll() async {
        invalidateLoadedState()
    }

    private func invalidateLoadedState() {
        loadEpoch &+= 1
        #if arch(arm64)
        inFlightLoad?.task.cancel()
        inFlightLoad = nil
        loadedModel = nil
        #endif
        loadedWithVision = false
        loadedDirectoryPath = nil
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }

    #if arch(arm64)
    private func embedSingleImageWithFallback(
        url: URL,
        model: EmbeddingModel,
        options: ImageEmbedOptions
    ) async -> [Float]? {
        do {
            let emb = try await model.embed(image: .url(url), options: options)
            return emb.vector
        } catch {
            guard let cgImage = loadNormalizedCGImage(from: url) else {
                Self.logger.warning(
                    "Semantic image decode skipped for \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
            do {
                let emb = try await model.embed(image: .cgImage(cgImage), options: options)
                return emb.vector
            } catch {
                Self.logger.warning(
                    "Semantic image embed failed for \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }
    }

    private func ensureModelLoaded(needsVision: Bool) async throws -> EmbeddingModel {
        guard SemanticModelLocator.isHardwareSupported else {
            throw SemanticEngineError.unsupportedHardware
        }
        let textURL: URL
        let mmprojURL: URL?
        let dirURL: URL

        let status = await modelStatus()
        switch status {
        case .ready(let resolvedText, let resolvedMMProj, let resolvedDir):
            textURL = resolvedText
            mmprojURL = needsVision ? resolvedMMProj : nil
            dirURL = resolvedDir
        case .missing(let resolvedDir, let missingFiles):
            if !needsVision, let resolvedText = SemanticModelLocator.resolveTextModelURL(in: resolvedDir) {
                textURL = resolvedText
                mmprojURL = nil
                dirURL = resolvedDir
            } else {
                throw SemanticEngineError.modelsMissing(missingFiles)
            }
        }

        let dirPath = dirURL.standardizedFileURL.path
        if let existing = loadedModel,
           loadedDirectoryPath == dirPath,
           (!needsVision || loadedWithVision) {
            return existing
        }

        if let pending = inFlightLoad,
           pending.dirPath == dirPath,
           (!needsVision || pending.includesVision) {
            return try await pending.task.value
        }

        loadEpoch &+= 1
        let epoch = loadEpoch
        inFlightLoad?.task.cancel()
        inFlightLoad = nil
        loadedModel = nil
        loadedWithVision = false
        loadedDirectoryPath = nil

        let loadOptions = LoadOptions(imageEncoder: mmprojURL)
        let loadTask = Task<EmbeddingModel, Error> {
            try await EmbeddingModel.load(from: textURL, options: loadOptions)
        }
        inFlightLoad = (task: loadTask, dirPath: dirPath, includesVision: needsVision, epoch: epoch)

        do {
            let model = try await loadTask.value
            if inFlightLoad?.epoch == epoch {
                inFlightLoad = nil
            }
            if loadEpoch == epoch {
                loadedModel = model
                loadedWithVision = needsVision
                loadedDirectoryPath = dirPath
            }
            return model
        } catch {
            if inFlightLoad?.epoch == epoch {
                inFlightLoad = nil
            }
            throw error
        }
    }
    #endif

    private func cacheQueryVector(_ vector: [Float], forKey key: String) {
        if queryCache[key] == nil {
            queryCacheOrder.append(key)
        }
        queryCache[key] = vector
        while queryCacheOrder.count > Self.maxCachedQueries {
            let evicted = queryCacheOrder.removeFirst()
            queryCache.removeValue(forKey: evicted)
        }
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        guard idleUnloadSeconds > 0 else { return }
        let ns = UInt64(idleUnloadSeconds * 1_000_000_000)
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled, let self else { return }
            await self.unloadAll()
        }
    }

    private func loadNormalizedCGImage(from url: URL, maxPixel: Int = 1024) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return thumb
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
