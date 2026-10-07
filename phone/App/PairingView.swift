import FeedProtocol
import SwiftUI
import VisionKit

struct PairingView: View {
    @EnvironmentObject private var model: FeedModel
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var pasting = false
    @State private var pasted = ""
    @State private var progress: String?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            CautionStripe(tone: Theme.tone(nil)).frame(height: 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Pair with your Mac").font(.largeTitle.weight(.bold))
                    VStack(alignment: .leading, spacing: 14) {
                        Step(number: 1, text: "On your Mac, click the key icon in the menu bar.")
                        Step(number: 2, text: "Choose **Paired Phones**, then **Pair an iPhone…**. A QR code opens on the Mac.")
                        Step(number: 3, text: "Tap the button below and point this phone at the code.")
                    }
                    Text("Or open Terminal on the Mac and run `opProxy pair-iphone`.")
                        .font(.footnote)
                        .foregroundStyle(Theme.dim)
                    Button {
                        scanning = true
                    } label: {
                        Label("Scan the Mac's code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(FilledButton())
                    .disabled(busy || !DataScannerViewController.isSupported)

                    if let progress {
                        HStack(spacing: 10) { ProgressView().tint(Theme.text); Text(progress) }
                    }
                    if let error {
                        Text(error).foregroundStyle(Theme.danger)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("This phone's fingerprint").font(.subheadline).foregroundStyle(Theme.dim)
                        Text(PhoneKey.fingerprint).font(.title3.monospaced().weight(.semibold))
                        Text("The Mac shows the same one when it asks you to confirm.").font(.footnote).foregroundStyle(Theme.dim)
                    }

                    DisclosureGroup("Paste a code instead", isExpanded: $pasting) {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Pairing code", text: $pasted)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.body.monospaced())
                                .padding(10)
                                .background(Theme.well, in: RoundedRectangle(cornerRadius: 8))
                            Button("Pair") { pair(pasted) }.buttonStyle(FilledButton()).disabled(busy || pasted.isEmpty)
                        }
                        .padding(.top, 8)
                    }
                    .foregroundStyle(Theme.dim)
                }
                .padding(20)
            }
        }
        .foregroundStyle(Theme.text)
        .background(Theme.background)
        .sheet(isPresented: $scanning) {
            QRScanner { payload in
                scanning = false
                pair(payload)
            }
            .ignoresSafeArea()
        }
    }

    private func pair(_ payload: String) {
        busy = true
        error = nil
        Task {
            let failure = await model.pair(qr: payload.trimmingCharacters(in: .whitespacesAndNewlines)) { progress = $0 }
            progress = nil
            error = failure
            busy = false
            // Opened from the empty queue to pair again: done here.
            if failure == nil { dismiss() }
        }
    }
}

/// Reads the first QR code the camera sees.
private struct QRScanner: UIViewControllerRepresentable {
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
                guard !done, let payload = code.payloadStringValue, CloudFeed.Rendezvous.parse(qr: payload) != nil else { continue }
                done = true
                scanner.stopScanning()
                found(payload)
            }
        }
    }
}

/// One numbered step of the pairing instructions.
private struct Step: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.stripeDark)
                .frame(width: 24, height: 24)
                .background(Theme.tone(nil), in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
