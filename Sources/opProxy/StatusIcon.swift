import AppKit

/// Menu bar artwork: a key with the time left underneath, or a red snapped key once the
/// daemon's 1Password authorization is gone.
enum StatusIcon {
    static let height: CGFloat = 22

    /// Template image, so it follows the menu bar's light/dark appearance.
    static func key(remaining label: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.black])
        let keyImage = symbol(color: .black)
        let width = max(keyImage.size.width, ceil(text.size().width)) + 2
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            keyImage.draw(in: NSRect(x: (width - keyImage.size.width) / 2, y: height - keyImage.size.height - 1,
                                     width: keyImage.size.width, height: keyImage.size.height))
            text.draw(at: NSPoint(x: (width - text.size().width) / 2, y: 0))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Proxying switched off: a plain crossed-out key, no time.
    static func disabled() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: "key.slash", accessibilityDescription: "opProxy off")!
            .withSymbolConfiguration(config)!
        image.isTemplate = true
        return image
    }

    /// The key broken across the shaft: the bow (right) stays put, the bit end (left) drops.
    static func snappedKey() -> NSImage {
        // Rasterized up front: a symbol drawn under a rotation otherwise renders soft.
        let keyImage = rasterized(symbol(color: .systemRed), scale: 4)
        let size = keyImage.size
        let width = size.width + 4
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let rect = NSRect(x: 3, y: (height - size.height) / 2 + 1, width: size.width, height: size.height)
            let breakX = rect.minX + size.width * 0.42
            NSGraphicsContext.saveGraphicsState()
            breakPath(x: breakX, rect: rect, leftSide: false).addClip()
            keyImage.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()

            NSGraphicsContext.saveGraphicsState()
            let pivot = NSPoint(x: breakX, y: rect.midY)
            let t = NSAffineTransform()
            t.translateX(by: pivot.x - 1.5, yBy: pivot.y - 0.5)
            t.rotate(byDegrees: 28)
            t.translateX(by: -pivot.x, yBy: -pivot.y)
            t.concat()
            breakPath(x: breakX, rect: rect, leftSide: true).addClip()
            keyImage.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func rasterized(_ image: NSImage, scale: CGFloat) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale),
                                   pixelsHigh: Int(image.size.height * scale), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: image.size)
        out.addRepresentation(rep)
        return out
    }

    private static func symbol(color: NSColor) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: "key.horizontal.fill", accessibilityDescription: "1Password authorization")!
            .withSymbolConfiguration(config)!
    }

    /// Region on one side of a zigzag vertical break at `x`.
    private static func breakPath(x: CGFloat, rect: NSRect, leftSide: Bool) -> NSBezierPath {
        let zig: [(CGFloat, CGFloat)] = [(0, 0), (0.9, 0.35), (-0.9, 0.5), (0.9, 0.65), (0, 1)]
        let edge = zig.map { NSPoint(x: x + $0.0, y: rect.minY + $0.1 * rect.height) }
        let outer = leftSide ? rect.minX - 20 : rect.maxX + 20
        let path = NSBezierPath()
        path.move(to: NSPoint(x: outer, y: rect.minY - 20))
        path.line(to: NSPoint(x: x, y: rect.minY - 20))
        edge.forEach { path.line(to: $0) }
        path.line(to: NSPoint(x: x, y: rect.maxY + 20))
        path.line(to: NSPoint(x: outer, y: rect.maxY + 20))
        path.close()
        return path
    }
}
