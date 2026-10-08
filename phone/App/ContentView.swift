import FeedProtocol
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: FeedModel

    var body: some View {
        Group {
            if model.paired {
                queue
            } else if model.loaded || model.pairedKeys != nil {
                PairingView().safeAreaInset(edge: .bottom) { StatusBar() }
            } else {
                // Nothing known yet (a fresh install): wait for iCloud rather than guess.
                Theme.background.ignoresSafeArea()
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
            // Only claim nothing is pending once iCloud has said so.
            Group { if model.loaded { empty } else { loading } }.zIndex(-.infinity)
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

    private var loading: some View {
        VStack(spacing: 0) {
            CautionStripe(tone: Theme.tone(nil)).frame(height: 8).opacity(0.5)
            Spinner(color: Theme.dim).frame(width: 36, height: 36).frame(maxHeight: .infinity)
        }
        .background(Theme.background)
    }

    private var empty: some View {
        VStack(spacing: 0) {
            CautionStripe(tone: Theme.tone(nil)).frame(height: 8).opacity(0.5)
            ContentUnavailableView("No pending requests", systemImage: "checkmark.shield",
                                   description: Text("When an agent asks for a secret, it shows up here."))
            UnpairButton()
            StatusBar()
        }
        .background(Theme.background)
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
                    label("Secret manager authorized · \(Duration.short(until.timeIntervalSince(context.date))) left",
                          systemImage: "key.fill", color: Theme.dim)
                }
            } else if !status.ok {
                label("Secret manager not authorized on the Mac", systemImage: "key.slash", color: Theme.danger)
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

/// Forgets the Mac, so this phone can pair again, with this or another Mac.
private struct UnpairButton: View {
    @EnvironmentObject private var model: FeedModel
    @State private var asking = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 6) {
            if let error { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
            Button("Unpair from the Mac") { asking = true }
                .font(.footnote)
                .foregroundStyle(Theme.dim)
        }
        .padding(.bottom, 12)
        .confirmationDialog("Unpair from the Mac?", isPresented: $asking, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) {
                Task { error = await model.unpair() }
            }
        } message: {
            Text("Requests stop coming to this phone until you pair it again.")
        }
    }
}
