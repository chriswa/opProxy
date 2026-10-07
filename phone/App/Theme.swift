import SwiftUI

/// Spaceterm's approval palette (Catppuccin Mocha), so a request looks the same on either app.
enum Theme {
    static let background = Color(hex: 0x11111B)
    static let surface = Color(hex: 0x181825)
    static let raised = Color(hex: 0x232336)
    static let border = Color(hex: 0x313244)
    static let text = Color(hex: 0xCDD6F4)
    static let dim = Color(hex: 0xA6ADC8)
    static let danger = Color(hex: 0xF38BA8)

    /// The document's tone: caution yellow unless it says otherwise.
    static func tone(_ name: String?) -> Color {
        switch name {
        case "danger": return danger
        case "info": return Color(hex: 0x89B4FA)
        default: return Color(hex: 0xF9E2AF)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Diagonal tone-and-black stripes, the caution tape across the top of a request.
struct CautionStripe: View {
    let tone: Color

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.background))
            var x: CGFloat = -size.height
            while x < size.width {
                var band = Path()
                band.move(to: CGPoint(x: x, y: size.height))
                band.addLine(to: CGPoint(x: x + size.height, y: 0))
                band.addLine(to: CGPoint(x: x + size.height + 10, y: 0))
                band.addLine(to: CGPoint(x: x + 10, y: size.height))
                context.fill(band, with: .color(tone))
                x += 20
            }
        }
    }
}
