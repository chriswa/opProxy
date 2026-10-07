import FeedProtocol
import SwiftUI

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
                    Text("Pair this phone with the Mac that asks for secrets, so its requests come here.")
                        .foregroundStyle(Theme.dim)
                    Button {
                        scanning = true
                    } label: {
                        Label("Scan the Mac's code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(FilledButton())
                    .disabled(busy)

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
            PairingGuide { payload in pair(payload) }
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
