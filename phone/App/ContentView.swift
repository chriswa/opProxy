import FeedProtocol
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: FeedModel
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.paired {
                    RequestList()
                } else {
                    PairingView()
                }
            }
            .navigationTitle("opProxy")
            .navigationDestination(for: String.self) { id in RequestView(id: id) }
            .safeAreaInset(edge: .bottom) { StatusBar() }
        }
        .tint(.teal)
        .onChange(of: model.focus) { _, id in
            guard let id else { return }
            path = [id]
            model.focus = nil
        }
    }
}

private struct RequestList: View {
    @EnvironmentObject private var model: FeedModel

    var body: some View {
        List {
            if model.items.isEmpty {
                ContentUnavailableView("No requests", systemImage: "key",
                                       description: Text("When an agent asks for a 1Password secret, it shows up here."))
            }
            ForEach(model.items) { item in
                NavigationLink(value: item.id) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.parsed?.title ?? "Request").font(.headline)
                        if let subtitle = item.parsed?.subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .refreshable { await model.refresh() }
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
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    label("\(status.label ?? "1Password") authorized · \(Self.left(until, now: context.date)) left",
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

    private static func left(_ until: Date, now: Date) -> String {
        let minutes = max(0, Int(until.timeIntervalSince(now) / 60))
        return minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m"
    }
}
