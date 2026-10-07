import FeedProtocol
import SwiftUI

/// One request, the whole screen. Who is asking and for what stay at the top, the choices and
/// the answers stay at the bottom, and the details between them scroll. Give each request its
/// own view identity, so a choice made on one never carries over to the next.
struct RequestView: View {
    /// How an answer the Mac accepted is acknowledged before the screen moves on.
    enum Outcome { case approved, denied }

    @EnvironmentObject private var model: FeedModel
    let item: FeedItem
    let waiting: Int
    @State private var picks: [String: String] = [:]
    @State private var sending = false
    @State private var error: String?
    @State private var outcome: Outcome?

    var body: some View {
        if let doc = item.parsed {
            screen(doc)
        } else {
            ContentUnavailableView("This request can't be shown", systemImage: "exclamationmark.triangle",
                                   description: Text("Answer it on the Mac, or update this app."))
        }
    }

    private func screen(_ doc: FeedDocument) -> some View {
        let tone = Theme.tone(doc.tone)
        return VStack(spacing: 0) {
            CautionStripe(tone: tone).frame(height: 8)
            header(doc, tone: tone)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let notice = doc.notice {
                        Text(notice)
                            .font(.subheadline)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(tone))
                    }
                    ForEach(doc.sections ?? [], id: \.self) { SectionView(section: $0) }
                }
                .padding(16)
            }
            .scrollIndicators(.visible)
            controls(doc, tone: tone)
        }
        .foregroundStyle(Theme.text)
        .background(Theme.background)
        .overlay { if let outcome { Acknowledgement(outcome: outcome) } }
        .onAppear {
            for picker in doc.pickers ?? [] where picks[picker.id] == nil {
                picks[picker.id] = picker.default ?? picker.options.first?.id
            }
        }
    }

    // MARK: Who and what

    private func header(_ doc: FeedDocument, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(doc.requester?.name ?? doc.subtitle ?? "Someone")
                        .font(.system(size: 30, weight: .bold))
                        .lineLimit(2)
                    Spacer()
                    if waiting > 0 {
                        Text("\(waiting) more").font(.footnote.monospacedDigit()).foregroundStyle(Theme.dim)
                    }
                }
                ForEach([doc.requester?.detail, doc.requester?.context].compactMap { $0 }, id: \.self) { line in
                    Text(line).font(.subheadline).foregroundStyle(Theme.dim).lineLimit(2)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Label {
                    Text(doc.item?.title ?? doc.title).font(.title2.weight(.semibold)).lineLimit(2)
                } icon: {
                    Image(systemName: "key.fill").foregroundStyle(tone)
                }
                if let detail = doc.item?.detail {
                    Text(detail).font(.subheadline).foregroundStyle(Theme.dim).padding(.leading, 34)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: Choices and answers

    private func controls(_ doc: FeedDocument, tone: Color) -> some View {
        let approve = doc.actions.first { $0.role == "approve" }
        let others = doc.actions.filter { $0.role != "approve" }
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(doc.pickers ?? [], id: \.self) { picker in
                PickerRows(picker: picker, choice: binding(picker), tone: tone)
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(Theme.danger)
            }
            HStack(spacing: 10) {
                ForEach(others, id: \.self) { action in
                    Button { send(action.id) } label: {
                        VStack(spacing: 1) {
                            Text(action.label).font(.subheadline.weight(.semibold))
                            // The deny button carries the countdown: it's what happens at zero.
                            if action.role == "deny", let expires = item.expires {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text(Self.clock(expires.timeIntervalSince(context.date)))
                                        .font(.caption2.monospacedDigit())
                                        .opacity(0.8)
                                }
                            }
                        }
                        .foregroundStyle(action.role == "deny" ? Theme.danger : Theme.text)
                        .frame(width: 84, height: 52)
                        .overlay(RoundedRectangle(cornerRadius: 26)
                            .stroke(action.role == "deny" ? Theme.danger : Theme.border, lineWidth: 1.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                    .disabled(sending || outcome != nil)
                }
                if let approve {
                    SlideToApprove(label: approve.label, busy: sending, done: outcome == .approved) { send(approve.id) }
                }
            }
        }
        .padding(16)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func binding(_ picker: FeedDocument.Picker) -> Binding<String?> {
        Binding(get: { picks[picker.id] }, set: { picks[picker.id] = $0 })
    }

    /// Sends the answer. The screen holds on to this request meanwhile, so it stays put
    /// through the acknowledgement even once it has left the queue, then lets it go.
    private func send(_ action: String) {
        sending = true
        error = nil
        model.hold(item)
        Task {
            let failure = await model.answer(item, action: action, picks: action == "approve" ? picks.compactMapValues { $0 } : [:])
            sending = false
            guard failure == nil else {
                error = failure
                model.hold(nil)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
            let approved = action == "approve"
            UINotificationFeedbackGenerator().notificationOccurred(approved ? .success : .warning)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { outcome = approved ? .approved : .denied }
            try? await Task.sleep(nanoseconds: 900_000_000)
            model.hold(nil)
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The answer, confirmed: a wash of its colour and a badge that pops in.
private struct Acknowledgement: View {
    let outcome: RequestView.Outcome
    @State private var shown = false

    var body: some View {
        let approved = outcome == .approved
        let color = approved ? Theme.approve : Theme.danger
        ZStack {
            color.opacity(shown ? 0.28 : 0).ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: approved ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 96, weight: .bold))
                    .foregroundStyle(.white, color)
                    .symbolEffect(.bounce, value: shown)
                Text(approved ? "Approved" : "Denied").font(.title.weight(.bold))
            }
            .padding(32)
            .background(Theme.well.opacity(0.92), in: RoundedRectangle(cornerRadius: 28))
            .scaleEffect(shown ? 1 : 0.4)
            .opacity(shown ? 1 : 0)
        }
        .onAppear { withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { shown = true } }
    }
}

/// Buttons dip when pressed, so a tap visibly lands.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// A picker as rows of toggle buttons, one per facet (Allow, then For), with the chosen
/// option's hint beneath. A picker without facets is a single row of its labels.
private struct PickerRows: View {
    let picker: FeedDocument.Picker
    @Binding var choice: String?
    let tone: Color

    private var chosen: FeedDocument.Option? { picker.options.first { $0.id == choice } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let rows = FacetRows(picker.options)
            if rows.names.isEmpty {
                row(picker.label ?? "", values: picker.options.map { ($0.label, $0.id == choice, true) }) { label in
                    choice = picker.options.first { $0.label == label }?.id
                }
            } else {
                ForEach(rows.names, id: \.self) { name in
                    let current = chosen.flatMap { rows.value(of: $0, name) }
                    row(name, values: rows.values(name).map { ($0, $0 == current, rows.reachable(name, $0, from: chosen)) }) { value in
                        choice = rows.choose(name, value, from: chosen)?.id ?? choice
                    }
                    .opacity(current == nil ? 0.4 : 1)
                }
            }
            if let hint = chosen?.hint {
                Text(hint).font(.caption).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ name: String, values: [(String, Bool, Bool)], pick: @escaping (String) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(name).font(.subheadline).foregroundStyle(Theme.dim).frame(width: 44, alignment: .leading)
            HStack(spacing: 6) {
                ForEach(values, id: \.0) { value, on, enabled in
                    Button { pick(value) } label: {
                        Text(value)
                            .font(.subheadline.weight(on ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .foregroundStyle(on ? Theme.stripeDark : Theme.text)
                            .background(on ? tone : Theme.well, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? tone : Theme.border))
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                }
            }
        }
    }
}

/// The options' facets as rows: which values each row offers, and which option a tap picks.
struct FacetRows {
    let options: [FeedDocument.Option]
    /// Facet names in the order options list them.
    let names: [String]

    init(_ options: [FeedDocument.Option]) {
        self.options = options
        var names: [String] = []
        for facet in options.flatMap({ $0.facets ?? [] }) where !names.contains(facet.name) { names.append(facet.name) }
        self.names = names
    }

    func values(_ name: String) -> [String] {
        var values: [String] = []
        for option in options {
            if let value = value(of: option, name), !values.contains(value) { values.append(value) }
        }
        return values
    }

    func value(of option: FeedDocument.Option, _ name: String) -> String? {
        option.facets?.first { $0.name == name }?.value
    }

    /// Whether some option has `value` for `name` and agrees with `current` on the rows above.
    func reachable(_ name: String, _ value: String, from current: FeedDocument.Option?) -> Bool {
        let above = names.prefix { $0 != name }
        return options.contains { option in
            self.value(of: option, name) == value
                && above.allSatisfy { row in self.value(of: option, row) == current.flatMap { self.value(of: $0, row) } }
        }
    }

    /// The option with `value` for `name` that keeps as many of the other rows' current
    /// values as it can; earlier options win ties.
    func choose(_ name: String, _ value: String, from current: FeedDocument.Option?) -> FeedDocument.Option? {
        options.filter { self.value(of: $0, name) == value }.max { a, b in
            score(a, current) < score(b, current) || (score(a, current) == score(b, current) && index(a) > index(b))
        }
    }

    /// How many rows `option` keeps at `current`'s values.
    private func score(_ option: FeedDocument.Option, _ current: FeedDocument.Option?) -> Int {
        names.filter { row in
            guard let mine = value(of: option, row) else { return false }
            return mine == current.flatMap { value(of: $0, row) }
        }.count
    }

    private func index(_ option: FeedDocument.Option) -> Int { options.firstIndex(of: option) ?? 0 }
}

private struct SectionView: View {
    let section: FeedDocument.Section

    var body: some View {
        if section.rows != nil || section.text != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let label = section.label { Text(label).font(.caption.weight(.semibold)).foregroundStyle(Theme.dim) }
                if let rows = section.rows {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(rows, id: \.self) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(row.label).foregroundStyle(Theme.dim).frame(width: 96, alignment: .leading)
                                Text(row.value)
                                    .font(row.mono == true ? .footnote.monospaced() : .subheadline)
                                    .textSelection(.enabled)
                            }
                            .font(.subheadline)
                        }
                    }
                } else if let text = section.text {
                    Text(text)
                        .font(section.mono == true ? .footnote.monospaced() : .subheadline)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                }
            }
        }
    }
}

/// Approving takes a deliberate drag all the way across, so a stray tap can't approve. Once
/// the answer is accepted (`done`), the knob stays at the end and turns into a tick.
struct SlideToApprove: View {
    let label: String
    let busy: Bool
    let done: Bool
    let action: () -> Void
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let knob: CGFloat = 44
            let travel = geo.size.width - knob - 8
            let filled = done ? travel : offset
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.approve.opacity(0.18)).overlay(Capsule().stroke(Theme.approve.opacity(0.7)))
                Capsule().fill(Theme.approve).frame(width: filled + knob + 8)
                Text(busy ? "Sending…" : "Slide to \(label.lowercased())")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.approve)
                    .frame(maxWidth: .infinity)
                    .padding(.leading, knob)
                    .opacity(done ? 0 : 1 - Double(offset / max(travel, 1)))
                Circle().fill(.white).frame(width: knob, height: knob)
                    .overlay(Image(systemName: done ? "checkmark" : "chevron.right.2")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Theme.approve)
                        .contentTransition(.symbolEffect(.replace)))
                    .offset(x: 4 + filled)
                    .gesture(DragGesture()
                        .onChanged { offset = min(max(0, $0.translation.width), travel) }
                        .onEnded { _ in
                            if offset >= travel - 2 {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                action()
                            } else {
                                withAnimation(.spring) { offset = 0 }
                            }
                        })
            }
            .animation(.spring(response: 0.3), value: done)
            // A failed send slides the knob back.
            .onChange(of: busy) { _, busy in if !busy && !done { withAnimation(.spring) { offset = 0 } } }
            .opacity(busy ? 0.7 : 1)
            .allowsHitTesting(!busy && !done)
        }
        .frame(height: 52)
    }
}
