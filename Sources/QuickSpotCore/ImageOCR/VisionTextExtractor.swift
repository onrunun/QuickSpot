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
        guard let supported = try? request.supportedRecognitionLanguages(), !supported.isEmpty else {
            return preferred
        }
        let supportedSet = Set(supported)
        let filtered = preferred.filter { supportedSet.contains($0) }
        return filtered.isEmpty ? ["en-US"] : filtered
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
