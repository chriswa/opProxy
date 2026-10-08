import FeedProtocol
import SwiftUI

struct PairingView: View {
    @EnvironmentObject private var model: FeedModel
    /// Called once paired, when shown as a sheet to pair another Mac.
    var onPaired: (() -> Void)?
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
                    if busy {
                        pairing
                    } else {
                        start
                    }
                }
                .padding(20)
            }
        }
        .foregroundStyle(Theme.text)
        .background(Theme.background)
        #if DEBUG
        .onAppear {
            switch Screenshot.current {
            case .guide: scanning = true
            case .confirm:
                busy = true
                progress = "Confirm on the Mac: check it shows the fingerprint below, then use Touch ID."
            default: break
            }
        }
        #endif
        .sheet(isPresented: $scanning) {
            PairingGuide { payload in pair(payload) }
        }
    }

    /// Before pairing, or after it failed: how to start.
    @ViewBuilder private var start: some View {
        Text("Pair with your Mac").font(.largeTitle.weight(.bold))
        Text("Pair this phone with the Mac that asks for secrets, so its requests come here.")
            .foregroundStyle(Theme.dim)
        if let error {
            Text(error).foregroundStyle(Theme.danger)
        }
        Button {
            scanning = true
        } label: {
            Label("Scan the Mac's code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
        }
        .buttonStyle(FilledButton())
        fingerprint
        DisclosureGroup("Paste a code instead", isExpanded: $pasting) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Pairing code", text: $pasted)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .padding(10)
                    .background(Theme.well, in: RoundedRectangle(cornerRadius: 8))
                Button("Pair") { pair(pasted) }.buttonStyle(FilledButton()).disabled(pasted.isEmpty)
            }
            .padding(.top, 8)
        }
        .foregroundStyle(Theme.dim)
        // For trying the app without a Mac (App Review, say): only before anything is paired.
        if onPaired == nil {
            Button("No Mac yet? Try a demo") { model.startDemo() }
                .font(.footnote)
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
    }

    /// While pairing: only the step it's on, and the fingerprint the Mac will ask about.
    @ViewBuilder private var pairing: some View {
        Text("Pairing…").font(.largeTitle.weight(.bold))
        HStack(alignment: .center, spacing: 12) {
            ProgressView().tint(Theme.text)
            Text(progress ?? "Starting…").font(.title3).fixedSize(horizontal: false, vertical: true)
        }
        fingerprint
    }

    private var fingerprint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This phone's fingerprint").font(.subheadline).foregroundStyle(Theme.dim)
            Text(PhoneKey.fingerprint).font(.title3.monospaced().weight(.semibold))
            Text("The Mac shows the same one when it asks you to confirm.").font(.footnote).foregroundStyle(Theme.dim)
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
            if failure == nil { onPaired?() }
        }
    }
}
