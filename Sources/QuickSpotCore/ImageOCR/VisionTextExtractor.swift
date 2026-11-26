import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Errors thrown when an image or document cannot be decoded or Vision OCR fails.
public enum OCRExtractionError: Error, Equatable, LocalizedError, Sendable {
    case unreadableImage
    case visionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return L10n.tr("ocr.error.unreadable")
        case .visionFailed(let message):
            return L10n.format("ocr.error.vision_failed", message)
        }
    }
}

/// Extracts text from images using Apple Vision OCR and folds multilingual text for instant FTS5 lookup.
public enum VisionTextExtractor {
    public static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "webp", "tiff", "tif", "bmp", "gif"
    ]

    private static let posixLocale = Locale(identifier: "en_US_POSIX")
    private static let supportedLanguagesLock = NSLock()
    private static var cachedSupportedLanguages: Set<String>?

    public static func isSupportedImage(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isSupportedDocument(_ url: URL) -> Bool {
        isSupportedImage(url) || url.pathExtension.lowercased() == "pdf"
    }

    public static func extractTextResult(from url: URL, maxPixel: Int = 2600) -> Result<String, Error> {
        if url.pathExtension.lowercased() == "pdf" {
            return PDFTextExtractor.extractTextResult(from: url)
        }
        return autoreleasepool {
            if let tiles = loadScrollingTilesIfNeeded(from: url, maxPixel: maxPixel) {
                var tileTexts: [String] = []
                tileTexts.reserveCapacity(tiles.count)
                var firstError: Error?
                for tile in tiles {
                    autoreleasepool {
                        do {
                            let text = try recognizeTextThrowing(in: tile)
                            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                tileTexts.append(text)
                            }
                        } catch {
                            if firstError == nil { firstError = error }
                        }
                    }
                }
                if tileTexts.isEmpty, let firstError {
                    return .failure(firstError)
                }
                return .success(mergeTiledOCRTexts(tileTexts))
            }

            guard let cgImage = loadCGImage(from: url, maxPixel: maxPixel) else {
                return .failure(OCRExtractionError.unreadableImage)
            }
            do {
                return .success(try recognizeTextThrowing(in: cgImage))
            } catch {
                return .failure(error)
            }
        }
    }

    /// Cooperative async variant that checks cancellation and yields/cools down between scrolling tiles and scanned PDF OCR pages.
    public static func extractTextResultAsync(
        from url: URL,
        maxPixel: Int = 2600,
        shouldContinue: (@Sendable () async -> Bool)? = nil,
        afterOCRUnit: (@Sendable (TimeInterval) async -> Void)? = nil
    ) async -> Result<String, Error> {
        if url.pathExtension.lowercased() == "pdf" {
            return await PDFTextExtractor.extractTextResultAsync(
                from: url,
                shouldContinue: shouldContinue,
                afterOCRPage: afterOCRUnit
            )
        }
        if let shouldContinue, !(await shouldContinue()) {
            return .failure(CancellationError())
        }
        if let tiles = autoreleasepool(invoking: { loadScrollingTilesIfNeeded(from: url, maxPixel: maxPixel) }) {
            var tileTexts: [String] = []
            tileTexts.reserveCapacity(tiles.count)
            var firstError: Error?
            for (index, tile) in tiles.enumerated() {
                if let shouldContinue, !(await shouldContinue()) {
                    return .failure(CancellationError())
                }
                let started = ProcessInfo.processInfo.systemUptime
                autoreleasepool {
                    do {
                        let text = try recognizeTextThrowing(in: tile)
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            tileTexts.append(text)
                        }
                    } catch {
                        if firstError == nil { firstError = error }
                    }
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                if index + 1 < tiles.count, let afterOCRUnit {
                    await afterOCRUnit(elapsed)
                }
            }
            if tileTexts.isEmpty, let firstError {
                return .failure(firstError)
            }
            return .success(mergeTiledOCRTexts(tileTexts))
        }

        return autoreleasepool {
            guard let cgImage = loadCGImage(from: url, maxPixel: maxPixel) else {
                return .failure(OCRExtractionError.unreadableImage)
            }
            do {
                return .success(try recognizeTextThrowing(in: cgImage))
            } catch {
                return .failure(error)
            }
        }
    }

    public static func extractText(from url: URL, maxPixel: Int = 2600) -> String {
        switch extractTextResult(from: url, maxPixel: maxPixel) {
        case .success(let text): return text
        case .failure: return ""
        }
    }

    public static func recognizeTextThrowing(in cgImage: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = resolvedRecognitionLanguages(for: request)
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch {
            throw OCRExtractionError.visionFailed(error.localizedDescription)
        }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private static func resolvedRecognitionLanguages(for request: VNRecognizeTextRequest) -> [String] {
        let preferred = L10n.preferredVisionLanguages()
        let supportedSet = supportedLanguages(for: request)
        guard !supportedSet.isEmpty else { return preferred }
        let filtered = preferred.filter { supportedSet.contains($0) }
        return filtered.isEmpty ? ["en-US"] : filtered
    }

    private static func supportedLanguages(for request: VNRecognizeTextRequest) -> Set<String> {
        supportedLanguagesLock.lock()
        if let cached = cachedSupportedLanguages {
            supportedLanguagesLock.unlock()
            return cached
        }
        supportedLanguagesLock.unlock()

        let resolved = Set((try? request.supportedRecognitionLanguages()) ?? [])
        if !resolved.isEmpty {
            supportedLanguagesLock.lock()
            cachedSupportedLanguages = resolved
            supportedLanguagesLock.unlock()
        }
        return resolved
    }

    public static func recognizeText(in cgImage: CGImage) -> String {
        do {
            return try recognizeTextThrowing(in: cgImage)
        } catch {
            return ""
        }
    }

    public static func normalizeForSearch(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "İ", with: "i")
            .replacingOccurrences(of: "I", with: "i")
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "ß", with: "ss")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: posixLocale)
    }

    public static func extractExcerpt(rawText: String, query: String, maxLength: Int = 140) -> String? {
        let lines = rawText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        let tokens = normalizeForSearch(query)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        let matched = lines.first { line in
            let folded = normalizeForSearch(line)
            return !tokens.isEmpty && tokens.allSatisfy { folded.contains($0) }
        } ?? lines.first { line in
            let folded = normalizeForSearch(line)
            return tokens.contains { folded.contains($0) }
        } ?? lines[0]

        if matched.count <= maxLength { return matched }
        return String(matched.prefix(maxLength - 1)) + "…"
    }

    /// Splits extreme-aspect-ratio scrolling screenshots into overlapping legible tiles instead of crushing width below readable pixel size.
    static func loadScrollingTilesIfNeeded(
        from url: URL,
        maxPixel: Int,
        aspectThreshold: Double = 2.5,
        maxTiles: Int = 8
    ) -> [CGImage]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        var w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        var h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        if let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue,
           (5...8).contains(orientation) {
            swap(&w, &h)
        }
        let major = max(w, h)
        let minor = min(w, h)
        guard minor > 0, major > maxPixel, Double(major) / Double(minor) >= aspectThreshold else {
            return nil
        }

        // Preserve legible minor-axis width while capping extreme total canvas dimensions.
        let maxCanvasMajor = min(major, maxPixel * maxTiles)
        let scaleForMinor = minor > maxPixel ? Double(maxPixel) / Double(minor) : 1.0
        let targetMajor = max(maxPixel, min(maxCanvasMajor, Int((Double(major) * scaleForMinor).rounded())))
        guard let fullImage = loadCGImage(from: url, maxPixel: targetMajor) else { return nil }

        let imgW = fullImage.width
        let imgH = fullImage.height
        let isVertical = imgH >= imgW
        let span = isVertical ? imgH : imgW
        let cross = isVertical ? imgW : imgH
        let tileSpan = min(maxPixel, max(cross * 2, 1200))
        guard span > tileSpan else { return [fullImage] }

        let overlap = max(60, Int(Double(tileSpan) * 0.10))
        let step = max(1, tileSpan - overlap)
        var tiles: [CGImage] = []
        var offset = 0
        while offset < span && tiles.count < maxTiles {
            let length = min(tileSpan, span - offset)
            let rect = isVertical
                ? CGRect(x: 0, y: offset, width: imgW, height: length)
                : CGRect(x: offset, y: 0, width: length, height: imgH)
            if let cropped = fullImage.cropping(to: rect) {
                tiles.append(cropped)
            }
            if offset + length >= span { break }
            offset += step
        }
        return tiles.isEmpty ? nil : tiles
    }

    /// Joins overlapping tile OCR outputs while deduplicating lines repeated across tile boundaries.
    static func mergeTiledOCRTexts(_ chunks: [String]) -> String {
        var mergedLines: [String] = []
        var recentNormalized: [String] = []

        for chunk in chunks {
            let lines = chunk
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var skippingOverlap = true
            for line in lines {
                let norm = normalizeForSearch(line)
                if skippingOverlap && !norm.isEmpty && recentNormalized.contains(norm) {
                    continue
                }
                skippingOverlap = false
                mergedLines.append(line)
            }
            recentNormalized = mergedLines.suffix(8).map { normalizeForSearch($0) }
        }
        return mergedLines.joined(separator: "\n")
    }

    private static func loadCGImage(from url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let largest = max(w, h)
        let targetMax = largest > 0 ? min(largest, maxPixel) : maxPixel

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: targetMax
        ]
        if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return thumb
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
