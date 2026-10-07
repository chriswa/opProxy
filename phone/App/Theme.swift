import SwiftUI

/// The Mac approval dialog's caution palette (`Caution` in ApprovalUI.swift): warm near-black
/// with hazard yellow, so a request looks the same on the phone as on the Mac.
enum Theme {
    static let background = Color(red: 0.12, green: 0.105, blue: 0.08)
    static let surface = Color(red: 0.17, green: 0.15, blue: 0.11)
    static let well = Color(red: 0.08, green: 0.07, blue: 0.055)
    static let border = Color(red: 0.96, green: 0.77, blue: 0.0).opacity(0.35)
    static let text = Color(red: 0.97, green: 0.95, blue: 0.91)
    static let dim = Color(red: 0.74, green: 0.70, blue: 0.62)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.30)
    static let approve = Color(red: 0.25, green: 0.78, blue: 0.42)
    static let stripeDark = Color(red: 0.07, green: 0.06, blue: 0.05)

    /// The document's tone: hazard yellow unless it says otherwise.
    static func tone(_ name: String?) -> Color {
        switch name {
        case "danger": return danger
        case "info": return Color(red: 0.45, green: 0.72, blue: 1.0)
        default: return Color(red: 0.98, green: 0.80, blue: 0.08)
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
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.stripeDark))
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
