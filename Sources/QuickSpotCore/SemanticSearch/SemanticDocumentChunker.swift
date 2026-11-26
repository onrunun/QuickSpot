import Foundation

/// Single passage chunk extracted from a PDF or OCR document for EmbeddingGemma 2 text embedding.
public struct SemanticTextChunk: Equatable, Sendable {
    public let index: Int
    public let embedInput: String
    public let excerpt: String

    public init(index: Int, embedInput: String, excerpt: String) {
        self.index = index
        self.embedInput = embedInput
        self.excerpt = excerpt
    }
}

/// Matched PDF or OCR text document returned by semantic chunk search.
public struct SemanticDocumentHit: Equatable, Sendable {
    public let path: String
    public let fileName: String
    public let kind: OCRDocumentKind
    public let excerpt: String
    public let similarity: Float
    public let zScore: Float
    public let mtime: Double

    public init(
        path: String,
        fileName: String,
        kind: OCRDocumentKind,
        excerpt: String,
        similarity: Float,
        zScore: Float = 0,
        mtime: Double = 0
    ) {
        self.path = path
        self.fileName = fileName
        self.kind = kind
        self.excerpt = excerpt
        self.similarity = similarity
        self.zScore = zScore
        self.mtime = mtime
    }
}

/// Corpus-aware search result from `SemanticDocumentStore`.
public struct SemanticDocumentSearchResult: Equatable, Sendable {
    public let hits: [SemanticDocumentHit]
    public let documentCount: Int
    public let mean: Float
    public let stdDev: Float
}

/// Splits long PDF/OCR texts into overlapping semantic chunks with title context and clean UI excerpts.
enum SemanticDocumentChunker {
    static let minDocumentCharacters = 40

    static func chunk(
        fileName: String,
        rawText: String,
        maxChunkChars: Int = 900,
        overlapChars: Int = 120,
        maxChunks: Int = 12
    ) -> [SemanticTextChunk] {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minDocumentCharacters else { return [] }

        let title = cleanTitle(from: fileName)
        let lines = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }

        var bodies: [String] = []
        var current = ""

        func flushCurrent() {
            let cleaned = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            bodies.append(cleaned)
        }

        for line in lines {
            if bodies.count >= maxChunks { break }
            if line.count > maxChunkChars {
                if !current.isEmpty {
                    flushCurrent()
                    current = overlapTail(of: current, limit: overlapChars)
                }
                var cursor = line.startIndex
                while cursor < line.endIndex && bodies.count < maxChunks {
                    let nextEnd = line.index(cursor, offsetBy: maxChunkChars, limitedBy: line.endIndex) ?? line.endIndex
                    let piece = String(line[cursor..<nextEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !piece.isEmpty {
                        bodies.append(piece)
                    }
                    if nextEnd >= line.endIndex { break }
                    let stepBack = min(overlapChars, maxChunkChars / 3)
                    cursor = line.index(nextEnd, offsetBy: -stepBack, limitedBy: cursor) ?? nextEnd
                }
                current = ""
                continue
            }

            let candidate = current.isEmpty ? line : "\(current)\n\(line)"
            if candidate.count <= maxChunkChars {
                current = candidate
            } else {
                flushCurrent()
                if bodies.count >= maxChunks { break }
                let overlap = overlapTail(of: current, limit: overlapChars)
                current = overlap.isEmpty ? line : "\(overlap)\n\(line)"
            }
        }
        if bodies.count < maxChunks {
            flushCurrent()
        }

        return bodies.prefix(maxChunks).enumerated().map { idx, body in
            let embedInput = title.isEmpty ? body : "title: \(title)\n\(body)"
            return SemanticTextChunk(
                index: idx,
                embedInput: embedInput,
                excerpt: makeExcerpt(from: body, maxLength: 150)
            )
        }
    }

    private static func cleanTitle(from fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        return base
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func overlapTail(of text: String, limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        let start = text.index(text.endIndex, offsetBy: -limit)
        let tail = String(text[start...])
        if let spaceIdx = tail.firstIndex(where: { $0.isWhitespace }) {
            return String(tail[tail.index(after: spaceIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return tail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeExcerpt(from body: String, maxLength: Int) -> String {
        let collapsed = body
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= maxLength { return collapsed }
        return String(collapsed.prefix(maxLength - 1)) + "…"
    }
}

/// Maps semantic PDF/OCR text hits into QuickSpot's calibrated `SearchItem` score band.
enum SemanticDocumentScorer {
    static func buildItems(
        from result: SemanticDocumentSearchResult,
        query: String,
        threshold: Float,
        minZScore: Float,
        relativeMargin: Float,
        minCorpusForZScore: Int,
        limit: Int
    ) -> [SearchItem] {
        guard let topSimilarity = result.hits.first?.similarity else { return [] }
        let enforceZScore = result.documentCount >= minCorpusForZScore
        let dynamicFloor = max(threshold, topSimilarity - relativeMargin)

        let surviving = result.hits.filter { hit in
            guard hit.similarity >= dynamicFloor else { return false }
            if enforceZScore && hit.zScore < minZScore { return false }
            return FileManager.default.fileExists(atPath: hit.path)
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
                id: "semtxt:\(hit.path)",
                title: hit.fileName,
                subtitle: parent,
                category: .file,
                iconPath: hit.path,
                score: score,
                action: .openFile(url),
                previewURL: url,
                matchedSnippet: hit.excerpt.isEmpty ? nil : hit.excerpt,
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

    static func calibratedScore(
        similarity: Float,
        topSimilarity: Float,
        rankIndex: Int,
        mtime: Double,
        now: Double,
        fileName: String,
        queryTokens: [String]
    ) -> Int {
        // Map EmbeddingGemma 2 text↔text cosine (0.675...0.855) into QuickSpot's 475...705 semantic content band.
        let clamped = max(0.0, min(1.0, Double((similarity - 0.675) / 0.180)))
        let base = Int((475.0 + clamped * 195.0).rounded())
        let gapPenalty = Int(max(0.0, Double(topSimilarity - similarity) * 800.0))
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
        return min(705, max(470, base - gapPenalty - rankPenalty + recencyBonus + filenameBonus))
    }
}
