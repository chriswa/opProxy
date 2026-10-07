import FeedProtocol
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: FeedModel
    @State private var pairing = false

    var body: some View {
        Group {
            if !model.paired {
                PairingView().safeAreaInset(edge: .bottom) { StatusBar() }
            } else {
                queue
            }
        }
        .foregroundStyle(Theme.text)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .tint(Theme.tone(nil))
    }

    /// The request on screen sits on top of whatever comes next. When it's answered or goes
    /// away, it slides off and uncovers the next request, or the empty queue, underneath.
    private var queue: some View {
        ZStack {
            empty.zIndex(-.infinity)
            if let item = model.current {
                RequestView(item: item, waiting: model.waiting)
                    .id(item.id)
                    // Older requests stack above newer ones, so the one leaving stays on top.
                    .zIndex(-item.createdAt)
                    .transition(.asymmetric(insertion: .identity,
                                            removal: .move(edge: .top).combined(with: .opacity)))
            }
        }
        .animation(.easeIn(duration: 0.35), value: model.current?.id)
    }

    private var empty: some View {
        VStack(spacing: 0) {
            CautionStripe(tone: Theme.tone(nil)).frame(height: 8).opacity(0.5)
            ContentUnavailableView {
                Label("No pending requests", systemImage: "checkmark.shield")
            } description: {
                Text("When an agent asks for a 1Password secret, it shows up here.")
            } actions: {
                Button("Pair with a Mac") { pairing = true }.buttonStyle(FilledButton())
            }
            StatusBar()
        }
        .background(Theme.background)
        .sheet(isPresented: $pairing) { PairingView() }
    }
}

/// The app's one filled button: hazard yellow with dark text.
struct FilledButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.stripeDark)
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
            .frame(minWidth: 200)
            .background(Theme.tone(nil), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
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
