import FeedProtocol
import SwiftUI
import VisionKit

struct PairingView: View {
    @EnvironmentObject private var model: FeedModel
    @State private var scanning = false
    @State private var pasted = ""
    @State private var progress: String?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                Text("On your Mac, open the opProxy menu, choose Paired Phones → Pair an iPhone…, then scan the code it shows.")
                Button("Scan the Mac's Code") { scanning = true }
                    .disabled(busy || !DataScannerViewController.isSupported)
            }
            Section("Or paste the code") {
                TextField("opproxy-pair:1:…", text: $pasted)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Button("Pair") { pair(pasted) }.disabled(busy || pasted.isEmpty)
            }
            Section("This phone's fingerprint") {
                Text(PhoneKey.fingerprint).font(.title3.monospaced().weight(.semibold))
            }
            if let progress {
                Section { HStack { ProgressView(); Text(progress) } }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
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
                guard !done, let payload = code.payloadStringValue, CloudFeed.Rendezvous.code(fromQR: payload) != nil else { continue }
                done = true
                scanner.stopScanning()
                found(payload)
            }
        }
    }
}
