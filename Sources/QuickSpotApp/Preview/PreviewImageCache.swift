import AVFoundation
import AppKit
import PDFKit
import QuickLookThumbnailing

/// Thread-safe thumbnail and full-resolution preview cache backed by Quick Look, PDFKit, and AVFoundation.
final class PreviewImageCache: @unchecked Sendable {
    static let shared = PreviewImageCache()

    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv"]
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.totalCostLimit = 48 << 20
    }

    func clear() {
        cache.removeAllObjects()
    }

    func cached(url: URL, side: CGFloat) -> NSImage? {
        cache.object(forKey: cacheKey(url: url, side: side))
    }

    func loadThumbnail(url: URL, side: CGFloat, scale: CGFloat) async -> NSImage? {
        if let hit = cached(url: url, side: side) { return hit }
        guard let cgImage = await Self.generateQuickLook(url: url, side: side, scale: scale, types: .thumbnail) else {
            return nil
        }
        return store(cgImage: cgImage, url: url, side: side, scale: scale)
    }

    func loadPreview(url: URL, side: CGFloat, scale: CGFloat) async -> NSImage? {
        if let hit = cached(url: url, side: side) { return hit }
        let ext = url.pathExtension.lowercased()
        let pixels = side * max(scale, 1)

        var cgImage: CGImage?
        if ext == "pdf" {
            cgImage = await Self.renderPDFPage(url: url, pixels: pixels)
        } else if Self.videoExtensions.contains(ext) {
            cgImage = await Self.extractVideoFrame(url: url, pixels: pixels)
        }
        if cgImage == nil {
            cgImage = await Self.generateQuickLook(url: url, side: side, scale: scale, types: .all)
        }
        guard let cgImage else { return nil }
        return store(cgImage: cgImage, url: url, side: side, scale: scale)
    }

    private func cacheKey(url: URL, side: CGFloat) -> NSString {
        "\(Int(side)):\(url.path)" as NSString
    }

    private func store(cgImage: CGImage, url: URL, side: CGFloat, scale: CGFloat) -> NSImage {
        let safeScale = max(scale, 1)
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / safeScale, height: CGFloat(cgImage.height) / safeScale)
        )
        let cost = cgImage.bytesPerRow * cgImage.height
        cache.setObject(image, forKey: cacheKey(url: url, side: side), cost: cost)
        return image
    }

    private nonisolated static func generateQuickLook(
        url: URL,
        side: CGFloat,
        scale: CGFloat,
        types: QLThumbnailGenerator.Request.RepresentationTypes
    ) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: max(scale, 1),
            representationTypes: types
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.cgImage)
            }
        }
    }

    private nonisolated static func renderPDFPage(url: URL, pixels: CGFloat) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
            let bounds = page.bounds(for: .cropBox)
            let fitScale = pixels / max(bounds.width, bounds.height, 1)
            let width = max(1, Int(bounds.width * fitScale))
            let height = max(1, Int(bounds.height * fitScale))
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }

            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: fitScale, y: fitScale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .cropBox, to: context)
            return context.makeImage()
        }.value
    }

    private nonisolated static func extractVideoFrame(url: URL, pixels: CGFloat) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixels, height: pixels)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        if let first = try? await generator.image(at: CMTime(seconds: 1.0, preferredTimescale: 600)).image {
            return first
        }
        return try? await generator.image(at: .zero).image
    }
}
