// Draws the iPhone app's icon: a hazard-yellow key under a stripe band, in the app's colours. Run: swift phone/make-icon.swift
import AppKit

let size: CGFloat = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
              : "phone/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// The app's caution palette (Theme.swift): warm near-black, hazard yellow, stripe black.
let yellow = NSColor(srgbRed: 0.98, green: 0.80, blue: 0.08, alpha: 1)
let black = NSColor(srgbRed: 0.07, green: 0.06, blue: 0.05, alpha: 1)
// iOS rounds the corners itself, so the background fills the square.
NSColor(srgbRed: 0.12, green: 0.105, blue: 0.08, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()
// A band of hazard stripes along the top, like the stripe across the top of the app's screens.
let band: CGFloat = 150
let top = size - band
black.setFill()
NSRect(x: 0, y: top, width: size, height: band).fill()
yellow.setFill()
var x: CGFloat = -band
while x < size {
    let stripe = NSBezierPath()
    stripe.move(to: NSPoint(x: x, y: top))
    stripe.line(to: NSPoint(x: x + 70, y: top))
    stripe.line(to: NSPoint(x: x + 70 + band, y: size))
    stripe.line(to: NSPoint(x: x + band, y: size))
    stripe.close()
    stripe.fill()
    x += 140
}
let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold).applying(.init(paletteColors: [yellow]))
let key = NSImage(systemSymbolName: "key.horizontal.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let ctx = NSGraphicsContext.current!.cgContext
ctx.translateBy(x: size / 2, y: top / 2)
ctx.rotate(by: .pi / 4)
key.draw(in: NSRect(x: -key.size.width / 2, y: -key.size.height / 2, width: key.size.width, height: key.size.height))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
