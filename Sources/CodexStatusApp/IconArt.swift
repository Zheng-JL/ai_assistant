import AppKit

/// The 搭子 artwork (a smiling chat bubble), drawn in code so the app icon and the
/// menu-bar glyph share one source.
enum IconArt {
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func context(_ pixels: Int) -> CGContext? {
        CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Maps unit coordinates (y up) to pixels, scaling by `k` about the point (cx, cy).
    private struct Layout {
        let size: CGFloat
        let k: CGFloat
        let cx: CGFloat
        let cy: CGFloat
        func x(_ v: CGFloat) -> CGFloat { ((v - cx) * k + 0.5) * size }
        func y(_ v: CGFloat) -> CGFloat { ((v - cy) * k + 0.5) * size }
        func len(_ v: CGFloat) -> CGFloat { v * k * size }
        func point(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: x(px), y: y(py)) }
        func rect(_ x0: CGFloat, _ y0: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x(x0), y: y(y0), width: len(w), height: len(h))
        }
    }

    /// Bubble and tail go into one path and are filled once, so no seam or double shadow shows between them.
    private static func fillBubble(_ ctx: CGContext, _ l: Layout) {
        ctx.addPath(CGPath(roundedRect: l.rect(0.20, 0.34, 0.60, 0.38), cornerWidth: l.len(0.13),
                           cornerHeight: l.len(0.13), transform: nil))
        // Same winding direction as the rounded rectangle, otherwise the overlap cancels out into a hole.
        ctx.move(to: l.point(0.27, 0.24))
        ctx.addLine(to: l.point(0.44, 0.40))
        ctx.addLine(to: l.point(0.30, 0.40))
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawFace(_ ctx: CGContext, _ l: Layout) {
        ctx.fillEllipse(in: l.rect(0.36, 0.50, 0.07, 0.09))
        ctx.fillEllipse(in: l.rect(0.57, 0.50, 0.07, 0.09))
        ctx.setLineWidth(l.len(0.025))
        ctx.setLineCap(.round)
        ctx.addArc(center: l.point(0.5, 0.52), radius: l.len(0.09), startAngle: .pi * 1.18,
                   endAngle: .pi * 1.82, clockwise: false)
        ctx.strokePath()
    }

    /// Bubble silhouette with the face cut out, in one colour (used for the menu-bar glyph).
    static func glyph(pixels: Int, color: CGColor) -> CGImage? {
        guard let ctx = context(pixels) else { return nil }
        let l = Layout(size: CGFloat(pixels), k: 1.42, cx: 0.5, cy: 0.48)
        ctx.setFillColor(color)
        fillBubble(ctx, l)
        ctx.setBlendMode(.clear)
        drawFace(ctx, l)
        return ctx.makeImage()
    }

    /// Rounded-square app icon: teal-to-blue gradient, white bubble, three status dots.
    static func appIcon(pixels: Int) -> CGImage? {
        guard let ctx = context(pixels) else { return nil }
        let s = CGFloat(pixels)
        let l = Layout(size: s, k: 1, cx: 0.5, cy: 0.54)
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x * s, y: y * s, width: w * s, height: h * s)
        }
        let body = CGPath(roundedRect: r(0.1, 0.1, 0.8, 0.8), cornerWidth: 0.18 * s, cornerHeight: 0.18 * s, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -0.014 * s), blur: 0.035 * s,
                      color: CGColor(gray: 0, alpha: 0.35))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.addPath(body)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        let gradient = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 0.20, green: 0.78, blue: 0.85, alpha: 1),
            CGColor(red: 0.20, green: 0.45, blue: 0.90, alpha: 1)
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0.12 * s, y: 0.9 * s),
                               end: CGPoint(x: 0.88 * s, y: 0.1 * s), options: [])
        let gloss = CGGradient(colorsSpace: space, colors: [
            CGColor(gray: 1, alpha: 0.20), CGColor(gray: 1, alpha: 0)
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gloss, start: CGPoint(x: 0.5 * s, y: 0.9 * s),
                               end: CGPoint(x: 0.5 * s, y: 0.52 * s), options: [])
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -0.012 * s), blur: 0.02 * s,
                      color: CGColor(gray: 0, alpha: 0.28))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        fillBubble(ctx, l)
        ctx.restoreGState()

        let ink = CGColor(red: 0.15, green: 0.20, blue: 0.50, alpha: 1)
        ctx.setFillColor(ink)
        ctx.setStrokeColor(ink)
        drawFace(ctx, l)

        // Three dots like a "typing…" indicator, in the green / orange / blue status colours.
        let dots: [(CGFloat, CGColor)] = [
            (0.56, CGColor(red: 0.20, green: 0.80, blue: 0.36, alpha: 1)),
            (0.66, CGColor(red: 1.00, green: 0.62, blue: 0.04, alpha: 1)),
            (0.76, CGColor(red: 0.20, green: 0.62, blue: 1.00, alpha: 1))
        ]
        for (x, color) in dots {
            let box = l.rect(x - 0.033, 0.805 - 0.033, 0.066, 0.066)
            ctx.setFillColor(color)
            ctx.fillEllipse(in: box)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            ctx.setLineWidth(0.008 * s)
            ctx.strokeEllipse(in: box)
        }
        return ctx.makeImage()
    }

    /// Black silhouette that macOS tints to match the menu bar.
    @MainActor
    static func menuBarImage() -> NSImage? {
        guard let cg = glyph(pixels: 44, color: CGColor(gray: 0, alpha: 1)) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        return image
    }

    /// Small coloured rounded-square badge with a white SF Symbol, used as a notification thumbnail.
    @MainActor
    static func badgePNG(symbol: String, color: NSColor, pixels: Int = 160) -> Data? {
        let size = CGFloat(pixels)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.04, dy: size * 0.04),
                         xRadius: size * 0.24, yRadius: size * 0.24).fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let glyph = (NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil))?
                .withSymbolConfiguration(configuration) {
                let box = glyph.size
                glyph.draw(in: NSRect(x: (rect.width - box.width) / 2, y: (rect.height - box.height) / 2,
                                      width: box.width, height: box.height))
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Writes the PNG sizes macOS expects for an .iconset folder.
    static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sizes: [(name: String, pixels: Int)] = [
            ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
            ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)
        ]
        for size in sizes {
            guard let image = appIcon(pixels: size.pixels),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: directory.appendingPathComponent("icon_\(size.name).png"))
        }
    }
}
