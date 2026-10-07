import FeedProtocol
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: FeedModel
    @State private var pairing = false

    var body: some View {
        Group {
            if !model.paired {
                PairingView().safeAreaInset(edge: .bottom) { StatusBar() }
            } else if let item = model.items.first {
                // The oldest request, alone; answering it (here or on the Mac) brings up the next.
                RequestView(item: item, waiting: model.items.count - 1).id(item.id)
            } else {
                ContentUnavailableView {
                    Label("No pending requests", systemImage: "checkmark.shield")
                } description: {
                    Text("When an agent asks for a 1Password secret, it shows up here.")
                } actions: {
                    Button("Pair with a Mac") { pairing = true }.foregroundStyle(Theme.dim)
                }
                .safeAreaInset(edge: .bottom) { StatusBar() }
                .sheet(isPresented: $pairing) { PairingView() }
            }
        }
        .foregroundStyle(Theme.text)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .tint(Theme.tone(nil))
    }
}

/// The 1Password authorization on the Mac, as the feed reports it.
private struct StatusBar: View {
    @EnvironmentObject private var model: FeedModel

    var body: some View {
        if let error = model.lastError {
            label(error, systemImage: "exclamationmark.icloud", color: .orange)
        } else if let status = model.status {
            if status.ok, let until = status.untilDate {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    label("\(status.label ?? "1Password") authorized · \(Duration.short(until.timeIntervalSince(context.date))) left",
                          systemImage: "key.fill", color: Theme.dim)
                }
            } else if !status.ok {
                label(status.title ?? "Not authorized", systemImage: "key.slash", color: .red)
            }
        }
    }

    private func label(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(Theme.surface)
    }
}
