import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// Renders QuickSpot's vector brand artwork (magnifying glass + lightning bolt) for both
/// the macOS menu bar template icon and the multi-resolution `AppIcon.icns` bundle asset.
enum BrandIcon {
    private static let iconsetSpecs: [(pixels: Int, filename: String)] = [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
    ]

    /// Resolution-independent monochrome template image for `NSStatusItem` (adapts to Light/Dark menu bars).
    static func menuBarImage(isIndexing: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let size = min(rect.width, rect.height)
            drawMenuBarGlyph(in: ctx, size: size)
            if isIndexing {
                let s = size / 18.0
                let dotRadius = 1.8 * s
                let dotRect = CGRect(
                    x: 15.6 * s - dotRadius,
                    y: 15.4 * s - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                )
                ctx.saveGState()
                NSColor.black.setFill()
                ctx.fillEllipse(in: dotRect)
                ctx.restoreGState()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "QuickSpot"
        return image
    }

    /// Full-color macOS squircle application icon at the requested pixel dimension.
    static func appIconImage(pixels: Int) -> NSImage {
        let rep = renderAppIconRep(pixels: pixels)
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.addRepresentation(rep)
        return image
    }

    /// Writes all required macOS `.iconset` PNG variants into `directory` for `iconutil -c icns`.
    static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for spec in iconsetSpecs {
            let rep = renderAppIconRep(pixels: spec.pixels)
            guard let pngData = rep.representation(using: .png, properties: [:]) else {
                throw NSError(
                    domain: "QuickSpot.BrandIcon",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to encode \(spec.filename)"]
                )
            }
            try pngData.write(to: directory.appendingPathComponent(spec.filename))
        }
    }

    private static func drawMenuBarGlyph(in ctx: CGContext, size: CGFloat) {
        let s = size / 18.0
        let lensCenter = CGPoint(x: 7.85 * s, y: 10.15 * s)
        let lensRadius = 5.55 * s
        let ringStroke = 1.65 * s

        ctx.saveGState()
        NSColor.black.setStroke()
        NSColor.black.setFill()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let ringRect = CGRect(
            x: lensCenter.x - lensRadius,
            y: lensCenter.y - lensRadius,
            width: lensRadius * 2,
            height: lensRadius * 2
        )
        ctx.setLineWidth(ringStroke)
        ctx.strokeEllipse(in: ringRect)

        let angle: CGFloat = -.pi / 4.0
        let handleStart = CGPoint(
            x: lensCenter.x + cos(angle) * (lensRadius + 0.4 * s),
            y: lensCenter.y + sin(angle) * (lensRadius + 0.4 * s)
        )
        let handleEnd = CGPoint(
            x: lensCenter.x + cos(angle) * (lensRadius + 4.75 * s),
            y: lensCenter.y + sin(angle) * (lensRadius + 4.75 * s)
        )
        ctx.move(to: handleStart)
        ctx.addLine(to: handleEnd)
        ctx.setLineWidth(2.0 * s)
        ctx.strokePath()

        ctx.addPath(lightningBoltPath(center: lensCenter, scale: lensRadius * 1.24))
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func renderAppIconRep(pixels px: Int) -> NSBitmapImageRep {
        let size = CGFloat(px)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: px,
            pixelsHigh: px,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        let cs = CGColorSpaceCreateDeviceRGB()

        // macOS HIG icon grid: 824x824 continuous squircle centered in 1024x1024 (tighter at <= 32px)
        let insetRatio: CGFloat = px <= 32 ? 0.06 : 0.09765625
        let box = CGRect(x: 0, y: 0, width: size, height: size)
            .insetBy(dx: size * insetRatio, dy: size * insetRatio)
        let cornerRadius = box.width * 0.2237
        let tilePath = appleSquirclePath(in: box, cornerRadius: cornerRadius)

        drawTileShadow(in: ctx, path: tilePath, size: size, pixels: px, colorSpace: cs)

        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.clip()

        let lensCenter = CGPoint(x: box.midX - box.width * 0.052, y: box.midY + box.height * 0.052)
        drawBackground(in: ctx, box: box, lensCenter: lensCenter, colorSpace: cs)
        drawMagnifyingGlass(in: ctx, box: box, lensCenter: lensCenter, size: size, pixels: px, colorSpace: cs)
        drawLightningBolt(in: ctx, box: box, lensCenter: lensCenter, size: size, pixels: px, colorSpace: cs)
        drawGlassRim(in: ctx, box: box, cornerRadius: cornerRadius, size: size, pixels: px, colorSpace: cs)

        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func drawTileShadow(
        in ctx: CGContext, path: CGPath, size: CGFloat, pixels px: Int, colorSpace cs: CGColorSpace
    ) {
        ctx.saveGState()
        if px >= 32 {
            ctx.setShadow(
                offset: CGSize(width: 0, height: -size * 0.014),
                blur: size * 0.028,
                color: rgba(cs, 0.02, 0.02, 0.08, 0.38)
            )
        }
        ctx.addPath(path)
        ctx.setFillColor(rgba(cs, 0.07, 0.09, 0.21, 1.0))
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func drawBackground(
        in ctx: CGContext, box: CGRect, lensCenter: CGPoint, colorSpace cs: CGColorSpace
    ) {
        let bgColors = [
            rgba(cs, 0.06, 0.08, 0.20, 1.0),
            rgba(cs, 0.18, 0.16, 0.49, 1.0),
            rgba(cs, 0.45, 0.22, 0.80, 1.0)
        ] as CFArray
        let bgGrad = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0.0, 0.52, 1.0])!
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: box.minX, y: box.minY),
            end: CGPoint(x: box.maxX, y: box.maxY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )

        let glowColors = [
            rgba(cs, 0.42, 0.64, 1.0, 0.36),
            rgba(cs, 0.56, 0.34, 0.98, 0.14),
            rgba(cs, 0.40, 0.20, 0.80, 0.0)
        ] as CFArray
        let glowGrad = CGGradient(colorsSpace: cs, colors: glowColors, locations: [0.0, 0.48, 1.0])!
        ctx.drawRadialGradient(
            glowGrad,
            startCenter: lensCenter,
            startRadius: 0,
            endCenter: lensCenter,
            endRadius: box.width * 0.54,
            options: []
        )

        let sheenColors = [rgba(cs, 1.0, 1.0, 1.0, 0.12), rgba(cs, 1.0, 1.0, 1.0, 0.0)] as CFArray
        let sheenGrad = CGGradient(colorsSpace: cs, colors: sheenColors, locations: [0.0, 1.0])!
        ctx.drawLinearGradient(
            sheenGrad,
            start: CGPoint(x: box.midX, y: box.maxY),
            end: CGPoint(x: box.midX, y: box.midY + box.height * 0.06),
            options: []
        )
    }

    private static func drawMagnifyingGlass(
        in ctx: CGContext, box: CGRect, lensCenter: CGPoint, size: CGFloat, pixels px: Int, colorSpace cs: CGColorSpace
    ) {
        let lensRadius = box.width * 0.245
        let ringStroke = box.width * (px <= 32 ? 0.084 : 0.068)
        let lensRect = CGRect(
            x: lensCenter.x - lensRadius,
            y: lensCenter.y - lensRadius,
            width: lensRadius * 2,
            height: lensRadius * 2
        )

        ctx.saveGState()
        ctx.addEllipse(in: lensRect)
        ctx.clip()
        let glassColors = [rgba(cs, 1.0, 1.0, 1.0, 0.18), rgba(cs, 0.55, 0.76, 1.0, 0.04)] as CFArray
        let glassGrad = CGGradient(colorsSpace: cs, colors: glassColors, locations: [0.0, 1.0])!
        ctx.drawLinearGradient(
            glassGrad,
            start: CGPoint(x: lensCenter.x - lensRadius, y: lensCenter.y + lensRadius),
            end: CGPoint(x: lensCenter.x + lensRadius, y: lensCenter.y - lensRadius),
            options: []
        )
        ctx.restoreGState()

        let angle: CGFloat = -.pi / 4.0
        let handleStart = CGPoint(
            x: lensCenter.x + cos(angle) * (lensRadius + ringStroke * 0.30),
            y: lensCenter.y + sin(angle) * (lensRadius + ringStroke * 0.30)
        )
        let handleEnd = CGPoint(
            x: lensCenter.x + cos(angle) * (lensRadius + box.width * 0.238),
            y: lensCenter.y + sin(angle) * (lensRadius + box.width * 0.238)
        )

        ctx.saveGState()
        if px >= 32 {
            ctx.setShadow(
                offset: CGSize(width: 0, height: -size * 0.012),
                blur: size * 0.028,
                color: rgba(cs, 0.03, 0.02, 0.14, 0.52)
            )
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        let strokePath = CGMutablePath()
        strokePath.addEllipse(in: lensRect)
        strokePath.move(to: handleStart)
        strokePath.addLine(to: handleEnd)
        ctx.addPath(strokePath.copy(strokingWithWidth: ringStroke, lineCap: .round, lineJoin: .round, miterLimit: 4))
        ctx.clip()

        let metalColors = [rgba(cs, 1.0, 1.0, 1.0, 1.0), rgba(cs, 0.89, 0.93, 1.0, 0.98)] as CFArray
        let metalGrad = CGGradient(colorsSpace: cs, colors: metalColors, locations: [0.0, 1.0])!
        ctx.drawLinearGradient(
            metalGrad,
            start: CGPoint(x: box.minX, y: box.maxY),
            end: CGPoint(x: box.maxX, y: box.minY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func drawLightningBolt(
        in ctx: CGContext, box: CGRect, lensCenter: CGPoint, size: CGFloat, pixels px: Int, colorSpace cs: CGColorSpace
    ) {
        let boltScale = box.width * 0.245 * 1.24
        let boltPath = lightningBoltPath(center: lensCenter, scale: boltScale)

        ctx.saveGState()
        if px >= 32 {
            ctx.setShadow(
                offset: .zero,
                blur: size * 0.036,
                color: rgba(cs, 1.0, 0.78, 0.16, 0.58)
            )
        }
        ctx.addPath(boltPath)
        ctx.clip()

        let boltColors = [
            rgba(cs, 1.0, 0.98, 0.72, 1.0),
            rgba(cs, 1.0, 0.79, 0.18, 1.0),
            rgba(cs, 0.98, 0.55, 0.06, 1.0)
        ] as CFArray
        let boltGrad = CGGradient(colorsSpace: cs, colors: boltColors, locations: [0.0, 0.55, 1.0])!
        ctx.drawLinearGradient(
            boltGrad,
            start: CGPoint(x: lensCenter.x, y: lensCenter.y + boltScale * 0.56),
            end: CGPoint(x: lensCenter.x, y: lensCenter.y - boltScale * 0.56),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        ctx.restoreGState()
    }

    private static func drawGlassRim(
        in ctx: CGContext, box: CGRect, cornerRadius: CGFloat, size: CGFloat, pixels px: Int, colorSpace cs: CGColorSpace
    ) {
        guard px >= 32 else { return }
        let rimWidth = max(1.0, size * 0.0055)
        let rimInset = rimWidth * 0.5
        let rimPath = appleSquirclePath(
            in: box.insetBy(dx: rimInset, dy: rimInset),
            cornerRadius: cornerRadius - rimInset
        )

        ctx.saveGState()
        ctx.addPath(rimPath.copy(strokingWithWidth: rimWidth, lineCap: .butt, lineJoin: .miter, miterLimit: 4))
        ctx.clip()

        let rimColors = [
            rgba(cs, 1.0, 1.0, 1.0, 0.34),
            rgba(cs, 1.0, 1.0, 1.0, 0.10),
            rgba(cs, 1.0, 1.0, 1.0, 0.06)
        ] as CFArray
        let rimGrad = CGGradient(colorsSpace: cs, colors: rimColors, locations: [0.0, 0.45, 1.0])!
        ctx.drawLinearGradient(
            rimGrad,
            start: CGPoint(x: box.midX, y: box.maxY),
            end: CGPoint(x: box.midX, y: box.minY),
            options: []
        )
        ctx.restoreGState()
    }

    private static func appleSquirclePath(in rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .path(in: rect)
            .cgPath
    }

    private static func lightningBoltPath(center: CGPoint, scale: CGFloat) -> CGPath {
        let points: [(CGFloat, CGFloat)] = [
            ( 0.11,  0.56),
            (-0.37, -0.05),
            (-0.04, -0.05),
            (-0.12, -0.56),
            ( 0.37,  0.05),
            ( 0.04,  0.05)
        ]
        let path = CGMutablePath()
        for (index, pt) in points.enumerated() {
            let point = CGPoint(x: center.x + pt.0 * scale, y: center.y + pt.1 * scale)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private static func rgba(_ cs: CGColorSpace, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
        CGColor(colorSpace: cs, components: [r, g, b, a])!
    }
}
