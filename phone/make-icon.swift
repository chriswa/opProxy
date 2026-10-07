// Draws the iPhone app's icon: a white key on opProxy's teal. Run: swift phone/make-icon.swift
import AppKit

let size: CGFloat = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
              : "phone/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// iOS rounds the corners itself, so the background fills the square.
NSGradient(starting: NSColor(srgbRed: 0.10, green: 0.62, blue: 0.62, alpha: 1),
           ending: NSColor(srgbRed: 0.03, green: 0.33, blue: 0.38, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -90)
let config = NSImage.SymbolConfiguration(pointSize: 560, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
let key = NSImage(systemSymbolName: "key.horizontal.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let ctx = NSGraphicsContext.current!.cgContext
ctx.translateBy(x: size / 2, y: size / 2)
ctx.rotate(by: .pi / 4)
key.draw(in: NSRect(x: -key.size.width / 2, y: -key.size.height / 2, width: key.size.width, height: key.size.height))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
