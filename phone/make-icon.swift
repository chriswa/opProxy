// Draws the iPhone app's icon: an agent and a key in hazard yellow under a stripe band, in the app's colours. Run: swift phone/make-icon.swift
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
// An agent (the robot, as drawn in the app) asking for a key.
func robot(in r: NSRect) {
    let w = r.width, h = r.height
    func rect(_ x: CGFloat, _ y: CGFloat, _ rw: CGFloat, _ rh: CGFloat) -> NSRect {
        // The app's drawing is top-down; flip into AppKit's bottom-up coordinates.
        NSRect(x: r.minX + x * w, y: r.maxY - (y + rh) * h, width: rw * w, height: rh * h)
    }
    yellow.setFill()
    NSBezierPath(rect: rect(0.47, 0.06, 0.06, 0.16)).fill()
    NSBezierPath(ovalIn: rect(0.41, 0, 0.18, 0.18)).fill()
    NSBezierPath(roundedRect: rect(0, 0.45, 0.1, 0.24), xRadius: w * 0.03, yRadius: w * 0.03).fill()
    NSBezierPath(roundedRect: rect(0.9, 0.45, 0.1, 0.24), xRadius: w * 0.03, yRadius: w * 0.03).fill()
    let head = NSBezierPath(roundedRect: rect(0.12, 0.24, 0.76, 0.66), xRadius: w * 0.16, yRadius: w * 0.16)
    head.append(NSBezierPath(ovalIn: rect(0.28, 0.42, 0.14, 0.14)))
    head.append(NSBezierPath(ovalIn: rect(0.58, 0.42, 0.14, 0.14)))
    head.append(NSBezierPath(roundedRect: rect(0.34, 0.68, 0.32, 0.07), xRadius: 6, yRadius: 6))
    head.windingRule = .evenOdd
    head.fill()
}
robot(in: NSRect(x: 110, y: top / 2 - 190, width: 380, height: 380))
let config = NSImage.SymbolConfiguration(pointSize: 300, weight: .semibold).applying(.init(paletteColors: [yellow]))
let key = NSImage(systemSymbolName: "key.horizontal.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let ctx = NSGraphicsContext.current!.cgContext
ctx.translateBy(x: 720, y: top / 2)
ctx.rotate(by: .pi / 4)
key.draw(in: NSRect(x: -key.size.width / 2, y: -key.size.height / 2, width: key.size.width, height: key.size.height))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
