import FeedProtocol
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: FeedModel

    var body: some View {
        NavigationStack {
            Group {
                if model.paired {
                    QueueView()
                } else {
                    PairingView()
                }
            }
            .navigationTitle("opProxy")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { StatusBar() }
        }
        .tint(.teal)
    }
}

/// The oldest pending request, alone. Answering it (here or on the Mac) brings up the next.
private struct QueueView: View {
    @EnvironmentObject private var model: FeedModel

    var body: some View {
        if let item = model.items.first {
            RequestView(item: item)
                .id(item.id)
                .toolbar {
                    if model.items.count > 1 {
                        ToolbarItem(placement: .topBarTrailing) {
                            Text("\(model.items.count - 1) more waiting").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
        } else {
            ContentUnavailableView("No pending requests", systemImage: "checkmark.shield",
                                   description: Text("When an agent asks for a 1Password secret, it shows up here."))
        }
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
                          systemImage: "key.fill", color: .teal)
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
            .background(.bar)
    }
}
