import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

/// Actionable entity extracted locally from an image (QR/barcode) or OCR/PDF text (IBAN, link, email).
public struct DetectedSmartEntity: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case qrURL
        case qrText
        case iban
        case url
        case email
    }

    public let id: String
    public let kind: Kind
    public let displayValue: String
    public let copyValue: String
    public let openURL: URL?

    /// High-precision entities safe to surface inline in the preview pane (QR/barcode and Mod-97 IBAN).
    /// Lower-signal entities (emails, web URLs) remain accessible via the `⌘K` action palette.
    public var isPreviewHighlighted: Bool {
        switch kind {
        case .qrURL, .qrText, .iban: return true
        case .url, .email: return false
        }
    }

    public init(kind: Kind, displayValue: String, copyValue: String, openURL: URL? = nil) {
        self.id = "\(kind.rawValue):\(copyValue.lowercased())"
        self.kind = kind
        self.displayValue = displayValue
        self.copyValue = copyValue
        self.openURL = openURL
    }
}

/// Errors produced by on-device Apple Vision subject isolation / background removal.
public enum BackgroundRemovalError: Error, Equatable, LocalizedError, Sendable {
    case unreadableImage
    case noSubjectDetected
    case renderFailed

    public var errorDescription: String? {
        switch self {
        case .unreadableImage: return L10n.tr("ocr.error.unreadable")
        case .noSubjectDetected: return L10n.tr("vision.bg_remove.no_subject")
        case .renderFailed: return L10n.tr("vision.bg_remove.failed")
        }
    }
}

/// On-demand, 100% local Apple Vision & Foundation preview intelligence:
/// subject background removal (macOS 14+), QR/barcode decoding, and IBAN/URL/email extraction.
public enum ImageIntelligenceService {
    private static let maxEntities = 6
    private static let maxBarcodeSide: CGFloat = 1800
    private static let ibanLengths: [String: Int] = [
        "AL": 28, "AD": 24, "AT": 20, "AZ": 28, "BH": 22, "BE": 16, "BA": 20, "BR": 29,
        "BG": 22, "CR": 22, "HR": 21, "CY": 28, "CZ": 24, "DK": 18, "DO": 28, "EE": 20,
        "FO": 18, "FI": 18, "FR": 27, "GE": 22, "DE": 22, "GI": 23, "GR": 27, "GL": 18,
        "GT": 28, "HU": 28, "IS": 26, "IQ": 23, "IE": 22, "IL": 23, "IT": 27, "JO": 30,
        "KZ": 20, "XK": 20, "KW": 30, "LV": 21, "LB": 28, "LI": 21, "LT": 20, "LU": 20,
        "MT": 31, "MR": 27, "MU": 30, "MD": 24, "MC": 27, "ME": 22, "NL": 18, "MK": 19,
        "NO": 15, "PK": 24, "PS": 29, "PL": 28, "PT": 25, "QA": 29, "RO": 24, "SM": 27,
        "SA": 24, "RS": 22, "SK": 24, "SI": 19, "ES": 24, "SE": 24, "CH": 21, "TN": 24,
        "TR": 26, "UA": 29, "AE": 23, "GB": 22, "VG": 24
    ]

    /// Isolates the foreground subject via macOS 14 `VNGenerateForegroundInstanceMaskRequest` and returns cropped transparent PNG bytes.
    public static func removeBackgroundToPNG(from url: URL) throws -> Data {
        guard url.isFileURL,
              let ciImage = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw BackgroundRemovalError.unreadableImage
        }
        return try removeBackgroundToPNG(from: ciImage)
    }

    /// Isolates foreground subject from an in-memory `CIImage` and renders cropped transparent PNG bytes.
    public static func removeBackgroundToPNG(from ciImage: CIImage) throws -> Data {
        try autoreleasepool {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                throw BackgroundRemovalError.renderFailed
            }

            guard let observation = request.results?.first,
                  !observation.allInstances.isEmpty else {
                throw BackgroundRemovalError.noSubjectDetected
            }

            let maskedBuffer: CVPixelBuffer
            do {
                maskedBuffer = try observation.generateMaskedImage(
                    ofInstances: observation.allInstances,
                    from: handler,
                    croppedToInstancesExtent: true
                )
            } catch {
                throw BackgroundRemovalError.renderFailed
            }

            let outputImage = CIImage(cvPixelBuffer: maskedBuffer)
            let context = CIContext(options: [.useSoftwareRenderer: false])
            guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
                  let pngData = context.pngRepresentation(of: outputImage, format: .RGBA8, colorSpace: sRGB, options: [:]) else {
                throw BackgroundRemovalError.renderFailed
            }
            return pngData
        }
    }

    /// Detects QR codes and barcodes in a local image file on-demand.
    public static func detectBarcodes(in url: URL) -> [DetectedSmartEntity] {
        guard url.isFileURL, VisionTextExtractor.isSupportedImage(url) else { return [] }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: false,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxBarcodeSide
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return []
            }
            return detectBarcodes(in: cgImage)
        }
    }

    /// Detects QR codes and barcodes from an in-memory `CGImage`.
    public static func detectBarcodes(in cgImage: CGImage) -> [DetectedSmartEntity] {
        autoreleasepool {
            let request = VNDetectBarcodesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return []
            }
            guard let observations = request.results, !observations.isEmpty else { return [] }

            var results: [DetectedSmartEntity] = []
            var seen = Set<String>()
            for obs in observations {
                guard let raw = obs.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty else { continue }
                let dedupeKey = raw.lowercased()
                guard seen.insert(dedupeKey).inserted else { continue }

                if let url = validatedWebURL(raw) {
                    let host = url.host ?? raw
                    results.append(DetectedSmartEntity(
                        kind: .qrURL,
                        displayValue: host,
                        copyValue: raw,
                        openURL: url
                    ))
                } else if let wifi = parseWiFiQR(raw) {
                    results.append(DetectedSmartEntity(
                        kind: .qrText,
                        displayValue: "Wi-Fi: \(wifi.ssid)",
                        copyValue: wifi.password.isEmpty ? raw : wifi.password
                    ))
                } else {
                    let short = raw.count > 36 ? String(raw.prefix(35)) + "…" : raw
                    results.append(DetectedSmartEntity(
                        kind: .qrText,
                        displayValue: short,
                        copyValue: raw
                    ))
                }
            }
            return results
        }
    }

    /// Extracts ISO 13616 Mod-97 validated IBANs, explicit web URLs, and email addresses from OCR or PDF text.
    public static func extractSmartEntities(from text: String, maxCount: Int = 6) -> [DetectedSmartEntity] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5, maxCount > 0 else { return [] }
        let bounded = trimmed.count > 16_000 ? String(trimmed.prefix(16_000)) : trimmed

        var entities: [DetectedSmartEntity] = []
        var seen = Set<String>()

        func appendUnique(_ entity: DetectedSmartEntity) {
            guard entities.count < maxCount else { return }
            let key = "\(entity.kind.rawValue):\(entity.copyValue.lowercased())"
            if seen.insert(key).inserted {
                entities.append(entity)
            }
        }

        // 1. ISO 13616 Mod-97 validated IBANs (global high-precision match for invoices/receipts).
        for iban in extractValidIBANs(from: bounded) {
            appendUnique(DetectedSmartEntity(
                kind: .iban,
                displayValue: formatIBAN(iban),
                copyValue: iban
            ))
        }

        // 2. Foundation NSDataDetector for explicit links and emails only (phone numbers omitted due to high global false positives).
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(bounded.startIndex..., in: bounded)
            let matches = detector.matches(in: bounded, options: [], range: range)
            for match in matches {
                if entities.count >= maxCount { break }
                guard match.resultType == .link, let url = match.url else { continue }
                let scheme = (url.scheme ?? "").lowercased()
                if scheme == "mailto" {
                    let email = url.absoluteString.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
                    let parts = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2, !parts[0].isEmpty, parts[1].contains(".") else { continue }
                    appendUnique(DetectedSmartEntity(
                        kind: .email,
                        displayValue: email,
                        copyValue: email,
                        openURL: url
                    ))
                } else if scheme == "http" || scheme == "https",
                          let swiftRange = Range(match.range, in: bounded),
                          let host = url.host,
                          host.contains(".") {
                    // Require explicit scheme or www. prefix in source text so filenames like README.md / script.py aren't misread as URLs.
                    let rawToken = bounded[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard rawToken.hasPrefix("http://") || rawToken.hasPrefix("https://") || rawToken.hasPrefix("www.") else {
                        continue
                    }
                    let cleanDisplay = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                    appendUnique(DetectedSmartEntity(
                        kind: .url,
                        displayValue: cleanDisplay,
                        copyValue: url.absoluteString,
                        openURL: url
                    ))
                }
            }
        }

        return entities
    }

    /// Combines barcode detection (for images) and OCR/text entity extraction into a single deduplicated strip.
    public static func analyzePreview(url: URL, ocrText: String?) -> [DetectedSmartEntity] {
        var combined: [DetectedSmartEntity] = []
        var seenCopy = Set<String>()

        if VisionTextExtractor.isSupportedImage(url) {
            for entity in detectBarcodes(in: url) {
                if seenCopy.insert(entity.copyValue.lowercased()).inserted {
                    combined.append(entity)
                }
            }
        }

        if let ocrText, !ocrText.isEmpty, combined.count < maxEntities {
            for entity in extractSmartEntities(from: ocrText, maxCount: maxEntities) {
                guard combined.count < maxEntities else { break }
                if seenCopy.insert(entity.copyValue.lowercased()).inserted {
                    combined.append(entity)
                }
            }
        }

        return combined
    }

    // MARK: - IBAN & QR Helpers

    static func extractValidIBANs(from text: String) -> [String] {
        let prefixPattern = #"\b([A-Za-z]{2})(\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: prefixPattern) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        var results: [String] = []
        var seen = Set<String>()

        for match in regex.matches(in: text, range: nsRange) {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            let country = text[swiftRange].prefix(2).uppercased()
            guard let expectedLength = ibanLengths[country] else { continue }

            var compact = ""
            compact.reserveCapacity(expectedLength)
            var cursor = swiftRange.lowerBound
            var validWalk = true

            while cursor < text.endIndex && compact.count < expectedLength {
                let ch = text[cursor]
                if ch.isASCII && (ch.isLetter || ch.isNumber) {
                    compact.append(contentsOf: ch.uppercased())
                } else if ch == " " || ch == "\t" || ch == "-" {
                    // Legal horizontal group separator inside an IBAN.
                } else {
                    validWalk = false
                    break
                }
                cursor = text.index(after: cursor)
            }

            guard validWalk, compact.count == expectedLength else { continue }
            if cursor < text.endIndex {
                let nextChar = text[cursor]
                if nextChar.isLetter || nextChar.isNumber { continue }
            }
            guard isValidIBAN(compact), seen.insert(compact).inserted else { continue }
            results.append(compact)
        }
        return results
    }

    /// Validates an IBAN against known country length and ISO 13616 Mod-97-10 checksum.
    public static func isValidIBAN(_ raw: String) -> Bool {
        let compact = raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard compact.count >= 15, compact.count <= 34 else { return false }
        let country = String(compact.prefix(2))
        guard let expectedLength = ibanLengths[country], compact.count == expectedLength else { return false }

        let rearranged = compact.dropFirst(4) + compact.prefix(4)
        var remainder = 0
        for ch in rearranged {
            guard let ascii = ch.asciiValue else { return false }
            if ascii >= 48 && ascii <= 57 {
                remainder = (remainder * 10 + Int(ascii - 48)) % 97
            } else if ascii >= 65 && ascii <= 90 {
                let val = Int(ascii - 55) // A=10 .. Z=35
                remainder = (remainder * 10 + val / 10) % 97
                remainder = (remainder * 10 + val % 10) % 97
            } else {
                return false
            }
        }
        return remainder == 1
    }

    private static func formatIBAN(_ compact: String) -> String {
        if compact.count > 18 {
            let first = compact.prefix(4)
            let second = compact.dropFirst(4).prefix(4)
            let last = compact.suffix(4)
            return "\(first) \(second) … \(last)"
        }
        var groups: [String] = []
        var idx = compact.startIndex
        while idx < compact.endIndex {
            let next = compact.index(idx, offsetBy: 4, limitedBy: compact.endIndex) ?? compact.endIndex
            groups.append(String(compact[idx..<next]))
            idx = next
        }
        return groups.joined(separator: " ")
    }

    private static func validatedWebURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host,
              host.contains(".") else {
            return nil
        }
        return url
    }

    private static func parseWiFiQR(_ raw: String) -> (ssid: String, password: String)? {
        guard raw.uppercased().hasPrefix("WIFI:") else { return nil }
        let body = String(raw.dropFirst(5))
        var ssid = ""
        var password = ""
        for field in body.split(separator: ";") {
            if field.hasPrefix("S:") { ssid = String(field.dropFirst(2)) }
            else if field.hasPrefix("P:") { password = String(field.dropFirst(2)) }
        }
        guard !ssid.isEmpty else { return nil }
        return (ssid, password)
    }
}
