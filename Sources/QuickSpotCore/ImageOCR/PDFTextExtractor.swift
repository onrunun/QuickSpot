import CoreGraphics
import Foundation
import PDFKit

/// Extracts embedded text from digital PDFs and runs Apple Vision OCR on scanned/image-only pages.
public enum PDFTextExtractor {
    private static let minEmbeddedCharacters = 20

    public static func extractTextResult(
        from url: URL,
        maxDigitalPages: Int = 80,
        maxOCRPages: Int = 8
    ) -> Result<String, Error> {
        extract(
            from: url,
            maxDigitalPages: maxDigitalPages,
            maxOCRPages: maxOCRPages,
            maxTotalPages: maxDigitalPages + maxOCRPages
        )
    }

    /// Cooperative async variant that yields and cools down between scanned/image-only PDF OCR pages.
    public static func extractTextResultAsync(
        from url: URL,
        maxDigitalPages: Int = 80,
        maxOCRPages: Int = 8,
        shouldContinue: (@Sendable () async -> Bool)? = nil,
        afterOCRPage: (@Sendable (TimeInterval) async -> Void)? = nil
    ) async -> Result<String, Error> {
        guard let doc = PDFDocument(url: url) else {
            return .failure(OCRExtractionError.unreadableImage)
        }
        if doc.isLocked {
            return .success("")
        }
        let maxTotalPages = maxDigitalPages + maxOCRPages
        let inspectLimit = min(doc.pageCount, max(0, maxTotalPages))
        var pages: [String] = []
        pages.reserveCapacity(min(inspectLimit, maxTotalPages))
        var digitalPagesRead = 0
        var ocrPagesRun = 0
        var firstError: Error?

        for index in 0..<inspectLimit {
            if digitalPagesRead >= maxDigitalPages && ocrPagesRun >= maxOCRPages { break }
            guard let page = doc.page(at: index) else { continue }
            let embedded = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            if embedded.count >= minEmbeddedCharacters {
                if digitalPagesRead < maxDigitalPages {
                    pages.append(embedded)
                    digitalPagesRead += 1
                }
            } else if ocrPagesRun < maxOCRPages {
                if let shouldContinue, !(await shouldContinue()) {
                    return .failure(CancellationError())
                }
                ocrPagesRun += 1
                let started = ProcessInfo.processInfo.systemUptime
                autoreleasepool {
                    guard let rendered = renderPage(page, maxPixel: 1800) else {
                        if firstError == nil { firstError = OCRExtractionError.unreadableImage }
                        return
                    }
                    do {
                        let ocr = try VisionTextExtractor.recognizeTextThrowing(in: rendered)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !ocr.isEmpty {
                            pages.append(ocr)
                        } else if !embedded.isEmpty {
                            pages.append(embedded)
                        }
                    } catch {
                        if firstError == nil { firstError = error }
                    }
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                let hasMoreOCRBudget = ocrPagesRun < maxOCRPages && (index + 1) < inspectLimit
                if hasMoreOCRBudget, let afterOCRPage {
                    await afterOCRPage(elapsed)
                }
            }
        }

        if pages.isEmpty, let firstError {
            return .failure(firstError)
        }
        return .success(pages.joined(separator: "\n"))
    }

    public static func extractText(from url: URL, maxPages: Int = 8) -> String {
        switch extract(from: url, maxDigitalPages: maxPages, maxOCRPages: maxPages, maxTotalPages: maxPages) {
        case .success(let text): return text
        case .failure: return ""
        }
    }

    private static func extract(
        from url: URL,
        maxDigitalPages: Int,
        maxOCRPages: Int,
        maxTotalPages: Int
    ) -> Result<String, Error> {
        autoreleasepool {
            guard let doc = PDFDocument(url: url) else {
                return .failure(OCRExtractionError.unreadableImage)
            }
            // Password-protected PDFs cannot yield page text or meaningful renders; keep filename indexed with empty text.
            if doc.isLocked {
                return .success("")
            }
            let inspectLimit = min(doc.pageCount, max(0, maxTotalPages))
            var pages: [String] = []
            pages.reserveCapacity(min(inspectLimit, maxDigitalPages + maxOCRPages))
            var digitalPagesRead = 0
            var ocrPagesRun = 0
            var firstError: Error?

            for index in 0..<inspectLimit {
                if digitalPagesRead >= maxDigitalPages && ocrPagesRun >= maxOCRPages { break }
                guard let page = doc.page(at: index) else { continue }
                let embedded = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

                if embedded.count >= minEmbeddedCharacters {
                    if digitalPagesRead < maxDigitalPages {
                        pages.append(embedded)
                        digitalPagesRead += 1
                    }
                } else if ocrPagesRun < maxOCRPages {
                    ocrPagesRun += 1
                    autoreleasepool {
                        guard let rendered = renderPage(page, maxPixel: 1800) else {
                            if firstError == nil { firstError = OCRExtractionError.unreadableImage }
                            return
                        }
                        do {
                            let ocr = try VisionTextExtractor.recognizeTextThrowing(in: rendered)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !ocr.isEmpty {
                                pages.append(ocr)
                            } else if !embedded.isEmpty {
                                pages.append(embedded)
                            }
                        } catch {
                            if firstError == nil { firstError = error }
                        }
                    }
                }
            }

            if pages.isEmpty, let firstError {
                return .failure(firstError)
            }
            return .success(pages.joined(separator: "\n"))
        }
    }

    private static func renderPage(_ page: PDFPage, maxPixel: Int) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        let largest = max(bounds.width, bounds.height, 1)
        let scale = CGFloat(maxPixel) / largest
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }
}
