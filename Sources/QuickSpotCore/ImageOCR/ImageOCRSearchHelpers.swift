import Foundation

/// Pure search-scoring, filter matching, and item construction helpers for `ImageOCRIndexer`.
enum OCRSearchHelpers {
    static func sqlKind(for filter: SearchKindFilter?) -> OCRDocumentKind? {
        switch filter {
        case .imagesOnly: return .image
        case .pdfOnly: return .pdf
        default: return nil
        }
    }

    static func buildItems(
        from rawHits: [OCRSearchHit],
        query: String,
        filter: SearchKindFilter?,
        limit: Int
    ) -> [SearchItem] {
        let surviving = rawHits.filter { hit in
            let url = URL(fileURLWithPath: hit.path)
            return ImageOCRIndexer.matchesFilter(filter, url: url) && FileManager.default.fileExists(atPath: hit.path)
        }

        let home = NSHomeDirectory()
        let queryTokens = ImageOCRIndexer.normalizedQueryTokens(from: query)
        let now = Date().timeIntervalSince1970

        let scored: [(index: Int, item: SearchItem)] = surviving.enumerated().map { idx, hit in
            let url = URL(fileURLWithPath: hit.path)
            let parent = url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~")
            let score = ImageOCRIndexer.calibratedOCRScore(
                rankIndex: idx, mtime: hit.mtime, now: now, fileName: hit.fileName, queryTokens: queryTokens
            )
            let item = SearchItem(
                id: "ocr:\(hit.path)",
                title: hit.fileName,
                subtitle: parent,
                category: .file,
                iconPath: hit.path,
                score: score,
                action: .openFile(url),
                previewURL: url,
                matchedSnippet: hit.excerpt.isEmpty ? nil : hit.excerpt,
                matchSource: .ocrContent
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

    static func needsIndexing(item: DiscoveredImage, existing: OCRIndexRecord?) -> Bool {
        guard let prev = existing else { return true }
        let fileChanged = abs(prev.mtime - item.mtime) > 0.001 || prev.size != item.size
        if fileChanged { return true }
        if prev.status == ImageOCRStore.statusPending { return true }
        if prev.status == ImageOCRStore.statusFailed {
            return prev.retryCount < ImageOCRStore.maxFailureRetries
        }
        return false
    }
}

public extension ImageOCRIndexer {
    static func parsePrefix(_ raw: String) -> (filter: SearchKindFilter?, cleanQuery: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .filtered(let filter, let term) = QueryParser.parse(trimmed).mode,
           filter == .imagesOnly || filter == .pdfOnly {
            return (filter, term)
        }
        return (nil, trimmed)
    }

    static func matchesFilter(_ filter: SearchKindFilter?, url: URL) -> Bool {
        switch filter {
        case .imagesOnly:
            return VisionTextExtractor.isSupportedImage(url)
        case .pdfOnly:
            return url.pathExtension.lowercased() == "pdf"
        case .filesOnly, .contentOnly, nil:
            return true
        case .foldersOnly, .appsOnly, .clipboard:
            return false
        }
    }

    static func calibratedOCRScore(
        rankIndex: Int,
        mtime: Double,
        now: Double,
        fileName: String,
        queryTokens: [String]
    ) -> Int {
        let rankBase = max(480, 640 - rankIndex * 14)
        let recencyBonus: Int
        if mtime <= 0 {
            recencyBonus = 0
        } else {
            let age = max(0, now - mtime)
            if age < 86_400 {
                recencyBonus = 45
            } else if age < 7 * 86_400 {
                recencyBonus = 30
            } else if age < 30 * 86_400 {
                recencyBonus = 15
            } else {
                recencyBonus = 0
            }
        }
        let foldedName = VisionTextExtractor.normalizeForSearch(fileName)
        let filenameBonus = queryTokens.contains(where: { foldedName.contains($0) }) ? 30 : 0
        return min(710, max(480, rankBase + recencyBonus + filenameBonus))
    }

    static func normalizedQueryTokens(from query: String) -> [String] {
        let all = VisionTextExtractor.normalizeForSearch(query)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let significant = all.filter { $0.count >= 2 }
        return significant.isEmpty ? all : significant
    }
}
