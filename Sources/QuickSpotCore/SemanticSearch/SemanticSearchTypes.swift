import AppKit
import Foundation

/// Live semantic image indexing progress exposed to Settings and the launcher status badge.
public struct SemanticIndexProgress: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case scanning
        case indexing(done: Int, total: Int)
        case paused(reason: String)
        case modelsMissing
    }

    public let state: State
    public let embeddedCount: Int
    public let embeddedDocumentCount: Int
    public let modelStatus: SemanticModelStatus

    public init(
        state: State,
        embeddedCount: Int,
        modelStatus: SemanticModelStatus,
        embeddedDocumentCount: Int = 0
    ) {
        self.state = state
        self.embeddedCount = embeddedCount
        self.embeddedDocumentCount = embeddedDocumentCount
        self.modelStatus = modelStatus
    }
}

/// Matched image returned by in-memory Accelerate vector similarity search.
public struct SemanticVectorHit: Equatable, Sendable {
    public let path: String
    public let fileName: String
    public let similarity: Float
    public let zScore: Float
    public let mtime: Double

    public init(path: String, fileName: String, similarity: Float, zScore: Float = 0, mtime: Double = 0) {
        self.path = path
        self.fileName = fileName
        self.similarity = similarity
        self.zScore = zScore
        self.mtime = mtime
    }
}

/// Vector similarity query result bundled with corpus distribution stats for z-score gating.
public struct SemanticVectorSearchResult: Equatable, Sendable {
    public let hits: [SemanticVectorHit]
    public let corpusCount: Int
    public let mean: Float
    public let stdDev: Float

    public init(hits: [SemanticVectorHit], corpusCount: Int, mean: Float, stdDev: Float) {
        self.hits = hits
        self.corpusCount = corpusCount
        self.mean = mean
        self.stdDev = stdDev
    }
}

/// Stored metadata snapshot used for incremental semantic re-indexing and retry-bound decisions.
public struct SemanticStoreEntry: Equatable, Sendable {
    public let mtime: Double
    public let size: Int64
    public let modelID: String
    public let status: Int
    public let retryCount: Int

    public init(mtime: Double, size: Int64, modelID: String, status: Int = 1, retryCount: Int = 0) {
        self.mtime = mtime
        self.size = size
        self.modelID = modelID
        self.status = status
        self.retryCount = retryCount
    }
}

/// Pure scoring & filtering helpers calibrated for EmbeddingGemma 2 cross-modal cosine distributions.
enum SemanticSearchScorer {
    static func buildItems(
        from result: SemanticVectorSearchResult,
        query: String,
        threshold: Float,
        minZScore: Float,
        relativeMargin: Float,
        minCorpusForZScore: Int,
        limit: Int
    ) -> [SearchItem] {
        guard let topSimilarity = result.hits.first?.similarity else { return [] }
        let enforceZScore = result.corpusCount >= minCorpusForZScore
        let dynamicFloor = max(threshold, topSimilarity - relativeMargin)

        let surviving = result.hits.filter { hit in
            guard hit.similarity >= dynamicFloor else { return false }
            if enforceZScore && hit.zScore < minZScore { return false }
            let url = URL(fileURLWithPath: hit.path)
            return VisionTextExtractor.isSupportedImage(url) && FileManager.default.fileExists(atPath: hit.path)
        }

        let home = NSHomeDirectory()
        let now = Date().timeIntervalSince1970
        let queryTokens = ImageOCRIndexer.normalizedQueryTokens(from: query)

        let scored: [(index: Int, item: SearchItem)] = surviving.enumerated().map { idx, hit in
            let url = URL(fileURLWithPath: hit.path)
            let parent = url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~")
            let score = calibratedScore(
                similarity: hit.similarity,
                topSimilarity: topSimilarity,
                rankIndex: idx,
                mtime: hit.mtime,
                now: now,
                fileName: hit.fileName,
                queryTokens: queryTokens
            )
            let item = SearchItem(
                id: "sem:\(hit.path)",
                title: hit.fileName,
                subtitle: parent,
                category: .file,
                iconPath: hit.path,
                score: score,
                action: .openFile(url),
                previewURL: url,
                matchedSnippet: L10n.tr("snippet.semantic_visual_match"),
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

    static func calibratedScore(
        similarity: Float,
        topSimilarity: Float,
        rankIndex: Int,
        mtime: Double,
        now: Double,
        fileName: String,
        queryTokens: [String]
    ) -> Int {
        // Map EmbeddingGemma 2 image↔text cosine similarity (0.635...0.780) into QuickSpot's 470...705 content band.
        let clamped = max(0.0, min(1.0, Double((similarity - 0.635) / 0.145)))
        let similarityBase = Int((470.0 + clamped * 195.0).rounded())
        let gapPenalty = Int(max(0.0, Double(topSimilarity - similarity) * 900.0))
        let rankPenalty = min(rankIndex * 8, 64)

        let recencyBonus: Int
        if mtime <= 0 {
            recencyBonus = 0
        } else {
            let age = max(0, now - mtime)
            if age < 86_400 { recencyBonus = 20 }
            else if age < 7 * 86_400 { recencyBonus = 12 }
            else if age < 30 * 86_400 { recencyBonus = 6 }
            else { recencyBonus = 0 }
        }

        let foldedName = VisionTextExtractor.normalizeForSearch(fileName)
        let filenameBonus = queryTokens.contains(where: { foldedName.contains($0) }) ? 25 : 0
        return min(705, max(465, similarityBase - gapPenalty - rankPenalty + recencyBonus + filenameBonus))
    }
}

/// Restores missing Turkish diacritics (e.g. `kopek` → `köpek`, `kirmizi` → `kırmızı`) using macOS's built-in `NSSpellChecker` with zero custom dictionary.
enum TurkishQueryRestorer {
    private static let lock = NSLock()
    private static let maxCacheEntries = 256
    private static var cache: [String: String?] = [:]
    private static var cacheOrder: [String] = []
    private static let asciiToTurkish: [Character: Character] = [
        "c": "ç", "g": "ğ", "i": "ı", "o": "ö", "s": "ş", "u": "ü"
    ]
    private static let turkishDiacritics = CharacterSet(charactersIn: "çğıöşüÇĞİÖŞÜ")

    /// Main-actor-safe async entry point for background search tasks, serving cache hits in O(1) without hopping threads.
    static func restoredVariantAsync(for query: String) async -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }
        guard shouldAttemptTurkishRestoration() else { return nil }

        let key = cacheKey(for: trimmed)
        if let cached = lookupCache(key) {
            return cached
        }
        return await MainActor.run {
            restoredVariant(for: trimmed)
        }
    }

    /// Returns a diacritic-restored Turkish variant if any word cleanly restores, otherwise `nil`.
    static func restoredVariant(for query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }
        guard shouldAttemptTurkishRestoration() else { return nil }

        let key = cacheKey(for: trimmed)
        if let cached = lookupCache(key) {
            return cached
        }

        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty, words.count <= 8 else { return nil }

        lock.lock()
        let checker = NSSpellChecker.shared
        var changed = false
        let restoredWords = words.map { word -> String in
            if let restored = restoreWord(word, using: checker) {
                changed = true
                return restored
            }
            return word
        }
        let result = changed ? restoredWords.joined(separator: " ") : nil
        storeCacheLocked(key: key, value: result)
        lock.unlock()
        return result
    }

    private static func cacheKey(for trimmed: String) -> String {
        "\(L10n.effectiveLanguage.rawValue)|\(trimmed.lowercased())"
    }

    private static func lookupCache(_ key: String) -> String?? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    private static func storeCacheLocked(key: String, value: String?) {
        if cache[key] == nil {
            cacheOrder.append(key)
        }
        cache[key] = value
        while cacheOrder.count > maxCacheEntries {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private static func shouldAttemptTurkishRestoration() -> Bool {
        if L10n.effectiveLanguage == .tr { return true }
        return Locale.preferredLanguages.contains { AppLanguage.match(identifier: $0) == .tr }
    }

    private static func restoreWord(_ word: String, using checker: NSSpellChecker) -> String? {
        let lower = word.lowercased()
        guard lower.count >= 3, lower.count <= 14 else { return nil }
        guard lower.rangeOfCharacter(from: turkishDiacritics) == nil else { return nil }
        guard lower.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }

        // If macOS Turkish spellchecker flags the ASCII spelling as misspelled, prefer its top diacritic-matching guess.
        let miss = checker.checkSpelling(of: lower, startingAt: 0, language: "tr", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        if miss.location != NSNotFound {
            let range = NSRange(location: 0, length: (lower as NSString).length)
            if let guesses = checker.guesses(forWordRange: range, in: lower, language: "tr", inSpellDocumentWithTag: 0) {
                for guess in guesses {
                    let gLower = guess.lowercased(with: Locale(identifier: "tr_TR"))
                    if gLower != lower && VisionTextExtractor.normalizeForSearch(gLower) == lower {
                        return gLower
                    }
                }
            }
        }

        // Fallback for ASCII forms accepted by the checker (e.g. `kopek`, `cocuk`, `kirmizi`): pick minimal valid diacritic edit.
        let chars = Array(lower)
        let positions = chars.indices.filter { asciiToTurkish[chars[$0]] != nil }
        guard !positions.isEmpty, positions.count <= 5 else { return nil }

        // Skip unambiguous common English words like `dog`, `cat`, `white`, `black` so English queries stay crisp.
        let enMiss = checker.checkSpelling(of: lower, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        let isCommonEnglish = (enMiss.location == NSNotFound && miss.location == NSNotFound && lower.count <= 4)
        if isCommonEnglish { return nil }

        var bestCandidate: String?
        var bestEdits = Int.max
        let limit = 1 << positions.count
        for mask in 1..<limit {
            let edits = mask.nonzeroBitCount
            if edits >= bestEdits { continue }
            var copy = chars
            for (bit, idx) in positions.enumerated() where (mask & (1 << bit)) != 0 {
                copy[idx] = asciiToTurkish[copy[idx]]!
            }
            let cand = String(copy)
            let candMiss = checker.checkSpelling(of: cand, startingAt: 0, language: "tr", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            if candMiss.location == NSNotFound {
                bestCandidate = cand
                bestEdits = edits
            }
        }
        return bestCandidate
    }
}
