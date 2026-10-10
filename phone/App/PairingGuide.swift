import FeedProtocol
import SwiftUI
import VisionKit

/// Shows where the Mac's pairing code comes from, a drawing of its menu bar menu with
/// "Pair an iPhone…" picked, then scans the code. The drawing follows the Mac's real menu
/// (MenuBarController in MenuBar.swift); update it when that menu changes.
struct PairingGuide: View {
    let found: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false

    var body: some View {
        VStack(spacing: 0) {
            CautionStripe(tone: Theme.tone(nil)).frame(height: 8)
            if scanning {
                QRScanner { payload in
                    dismiss()
                    found(payload)
                }
                .ignoresSafeArea(edges: .bottom)
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Open the code on your Mac").font(.title.weight(.bold))
                    Text("Click the key in the Mac's menu bar and choose **Pair an iPhone…**")
                        .foregroundStyle(Theme.dim)
                    MenuMock()
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                    Text("Or run `opProxy pair-iphone` in the Mac's Terminal.")
                        .font(.footnote)
                        .foregroundStyle(Theme.dim)
                    Button {
                        scanning = true
                    } label: {
                        Label("The code is showing: scan it", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(FilledButton())
                    .disabled(!DataScannerViewController.isSupported)
                }
                .padding(20)
            }
        }
        .foregroundStyle(Theme.text)
        .background(Theme.background)
        .presentationDragIndicator(.visible)
    }
}

/// A drawing of the Mac's menu bar with opProxy's key menu open and "Pair an iPhone…"
/// highlighted, in macOS's dark menu style.
private struct MenuMock: View {
    @State private var pulse = false

    private struct Row: Hashable {
        let title: String
        var dim = false
        var check = false
        var submenu = false
        var picked = false
        var separator = false
    }

    private let rows: [Row] = [
        Row(title: "Authorized · 11h 32m left", dim: true),
        Row(title: "Expires at 4:23 AM", dim: true),
        Row(title: "", separator: true),
        Row(title: "Refresh Now"),
        Row(title: "", separator: true),
        Row(title: "Recent Approvals", dim: true),
        Row(title: "", separator: true),
        Row(title: "Pair an iPhone…", picked: true),
        Row(title: "Paired Phones", submenu: true),
        Row(title: "Installed", check: true),
        Row(title: "Open at Login", check: true),
    ]

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            menuBar
            menu.padding(.trailing, 28)
        }
        .font(.system(size: 13))
        .padding(10)
        .background(
            LinearGradient(colors: [Color(red: 0.20, green: 0.27, blue: 0.40), Color(red: 0.11, green: 0.13, blue: 0.20)],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12)))
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The Mac's menu bar, with the key menu open and Pair an iPhone highlighted")
    }

    private var menuBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            // The key, as opProxy draws it, with the time its authorization has left.
            HStack(spacing: 3) {
                Image(systemName: "key.horizontal.fill")
                Text("12h").font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.white.opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
            Text("Tue 4:23 PM")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .background(.black.opacity(0.35))
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows, id: \.self) { row in
                if row.separator {
                    Rectangle().fill(.white.opacity(0.15)).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 10)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).opacity(row.check ? 1 : 0)
                        Text(row.title)
                        Spacer(minLength: 16)
                        if row.submenu { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)) }
                    }
                    .foregroundStyle(row.picked ? .white : .white.opacity(row.dim ? 0.45 : 0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(row.picked ? Color.accentBlue.opacity(pulse ? 1 : 0.7) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(alignment: .trailing) {
                        if row.picked {
                            Image(systemName: "cursorarrow")
                                .font(.system(size: 18))
                                .foregroundStyle(.white, .black)
                                .offset(x: 10, y: 9)
                        }
                    }
                    .padding(.horizontal, 5)
                }
            }
        }
        .padding(.vertical, 5)
        .frame(width: 230)
        .background(Color(red: 0.16, green: 0.16, blue: 0.18).opacity(0.96), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.18)))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
    }
}

private extension Color {
    /// macOS's menu selection blue.
    static let accentBlue = Color(red: 0.0, green: 0.42, blue: 0.95)
}

/// Reads the first pairing code the camera sees.
struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false

        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                guard !done, let payload = code.payloadStringValue,
                      CloudFeed.Rendezvous.parseSealed(qr: payload) != nil || CloudFeed.Rendezvous.parse(qr: payload) != nil
                else { continue }
                done = true
                scanner.stopScanning()
                found(payload)
            }
        }
    }
}
