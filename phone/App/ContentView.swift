import FeedProtocol
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: FeedModel

    var body: some View {
        Group {
            if model.paired {
                queue
            } else if model.loaded {
                PairingView().safeAreaInset(edge: .bottom) { ErrorBar() }
            } else {
                // Nothing known yet (a fresh install): wait for iCloud rather than guess.
                Theme.background.ignoresSafeArea().overlay(alignment: .bottom) { ErrorBar() }
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
            Group { if model.loaded { EmptyQueue() } else { loading } }.zIndex(-.infinity)
            if let request = model.current {
                RequestView(request: request, waiting: model.waiting)
                    .id(request.id)
                    // Older requests stack above newer ones, so the one leaving stays on top.
                    .zIndex(-request.item.createdAt)
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
            ErrorBar()
        }
        .background(Theme.background)
    }
}

/// Nothing pending: says so, and lists the paired Macs, each with its secret manager's
/// status and a way to unpair, and offers to pair another.
private struct EmptyQueue: View {
    @EnvironmentObject private var model: FeedModel
    @State private var pairing = false

    var body: some View {
        VStack(spacing: 0) {
            CautionStripe(tone: Theme.tone(nil)).frame(height: 8).opacity(0.5)
            ContentUnavailableView("No pending requests", systemImage: "checkmark.shield",
                                   description: Text("When an agent asks for a secret, it shows up here."))
            VStack(alignment: .leading, spacing: 10) {
                Text("Paired Macs").font(.footnote.weight(.semibold)).foregroundStyle(Theme.dim)
                ForEach(model.pairedMacs, id: \.zoneID) { MacRow(mac: $0) }
                Button {
                    pairing = true
                } label: {
                    Label("Pair another Mac", systemImage: "plus").font(.subheadline)
                }
                .foregroundStyle(Theme.tone(nil))
                .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            ErrorBar()
        }
        .background(Theme.background)
        .sheet(isPresented: $pairing) { PairingView(onPaired: { pairing = false }) }
    }
}

/// A paired Mac: its name, how long its secret manager's authorization has left, and Unpair.
private struct MacRow: View {
    @EnvironmentObject private var model: FeedModel
    let mac: MacFeed
    @State private var asking = false
    @State private var error: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer").foregroundStyle(Theme.dim).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(mac.displayName).font(.subheadline.weight(.semibold))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(error ?? Self.status(mac, now: context.date))
                        .font(.caption)
                        .foregroundStyle(error == nil ? Theme.dim : Theme.danger)
                }
            }
            Spacer()
            Button("Unpair") { asking = true }.font(.footnote).foregroundStyle(Theme.dim)
        }
        .confirmationDialog("Unpair from \(mac.displayName)?", isPresented: $asking, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { Task { error = await model.unpair(mac) } }
        } message: {
            Text("Its requests stop coming to this phone until you pair it again.")
        }
    }

    private static func status(_ mac: MacFeed, now: Date) -> String {
        guard let status = mac.status else { return "Paired" }
        if status.ok, let until = status.untilDate { return "Secret manager authorized · \(Duration.short(until.timeIntervalSince(now))) left" }
        return status.ok ? "Secret manager authorized" : "Secret manager not authorized on this Mac"
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

/// What went wrong talking to iCloud, if anything.
private struct ErrorBar: View {
    @EnvironmentObject private var model: FeedModel

    var body: some View {
        if let error = model.lastError {
            Label(error, systemImage: "exclamationmark.icloud")
                .font(.footnote)
                .foregroundStyle(Theme.danger)
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(Theme.surface)
        }
    }
}
