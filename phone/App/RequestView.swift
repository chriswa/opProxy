import FeedProtocol
import SwiftUI

/// One request, the whole screen. Who is asking and for what stay at the top, the choices and
/// the answers stay at the bottom, and the details between them scroll. Give each request its
/// own view identity, so a choice made on one never carries over to the next.
struct RequestView: View {
    /// An answer on its way: shown at once, then confirmed when the Mac accepts it.
    struct Answer: Equatable {
        let approved: Bool
        var confirmed = false
    }

    @EnvironmentObject private var model: FeedModel
    let request: QueuedRequest
    let waiting: Int
    private var item: FeedItem { request.item }
    @State private var picks: [String: String] = [:]
    @State private var error: String?
    @State private var answer: Answer?

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
            // Everything but the answers scrolls, so a long request never crowds them out.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(doc, tone: tone)
                    if let notice = doc.notice {
                        Text(notice)
                            .font(.subheadline)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(tone))
                            .padding(.horizontal, 16)
                    }
                    // Well apart from who and what: there if wanted, quiet otherwise.
                    details(doc)
                        .padding(.top, 28)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                }
            }
            .scrollIndicators(.visible)
            controls(doc, tone: tone)
        }
        .foregroundStyle(Theme.text)
        .background(Theme.background)
        .overlay { if let answer { Acknowledgement(answer: answer) } }
        #if DEBUG
        .onAppear { if Screenshot.current == .allowed { answer = Answer(approved: true, confirmed: true) } }
        #endif
        .onAppear {
            for picker in doc.pickers ?? [] where picks[picker.id] == nil {
                picks[picker.id] = picker.default ?? picker.options.first?.id
            }
        }
    }

    // MARK: Who and what

    private static let iconWidth: CGFloat = 28

    private func header(_ doc: FeedDocument, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 48) {
            // The Mac, when there's more than one to tell apart, and the agent on it.
            VStack(alignment: .leading, spacing: 14) {
                if model.pairedMacs.count > 1 {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(tone)
                            .frame(width: Self.iconWidth, height: Self.iconWidth)
                            .padding(.top, 4)
                        Text(request.macName).font(.system(size: 30, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    RobotIcon(color: tone).frame(width: Self.iconWidth, height: Self.iconWidth).padding(.top, 4)
                        .anchorPreference(key: IconBounds.self, value: .bounds) { ["robot": $0] }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(doc.requester?.name ?? doc.subtitle ?? "Someone")
                            .font(.system(size: 30, weight: .bold))
                            .lineLimit(2)
                        ForEach([doc.requester?.detail, doc.requester?.context].compactMap { $0 }, id: \.self) { line in
                            Text(line).font(.subheadline).foregroundStyle(Theme.dim).lineLimit(2)
                        }
                    }
                    .anchorPreference(key: IconBounds.self, value: .bounds) { ["requester": $0] }
                    Spacer(minLength: 0)
                    if waiting > 0 {
                        Text("\(waiting) more").font(.footnote.monospacedDigit()).foregroundStyle(Theme.dim).padding(.top, 8)
                    }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                // The app icon's key: horizontal, turned so its bow is at the top right.
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .rotationEffect(.degrees(-45))
                    .foregroundStyle(tone)
                    .frame(width: Self.iconWidth, height: Self.iconWidth)
                    .anchorPreference(key: IconBounds.self, value: .bounds) { ["key": $0] }
                VStack(alignment: .leading, spacing: 3) {
                    Text(doc.item?.title ?? doc.title).font(.title2.weight(.semibold)).lineLimit(2)
                    if let detail = doc.item?.detail {
                        Text(detail).font(.subheadline).foregroundStyle(Theme.dim)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlayPreferenceValue(IconBounds.self) { anchors in
            GeometryReader { geo in
                if let robot = anchors["robot"].map({ geo[$0] }), let key = anchors["key"].map({ geo[$0] }) {
                    // The question mark sits in the gap between the two rows, below the agent's lines.
                    let gapTop = anchors["requester"].map { geo[$0].maxY } ?? robot.maxY
                    AsksFor(tone: tone, from: CGPoint(x: robot.midX, y: robot.maxY + 6), to: CGPoint(x: key.midX, y: key.minY - 8),
                            mark: gapTop + (key.minY - gapTop) * 0.4)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    /// The exact command line and the agent's last message, small and dim. Documents from
    /// providers that don't send them get their sections instead.
    @ViewBuilder
    private func details(_ doc: FeedDocument) -> some View {
        if let context = doc.context {
            VStack(alignment: .leading, spacing: 32) {
                if let command = context.command {
                    detail("Command") { Text(command).font(.footnote.monospaced()) }
                }
                if let message = context.message {
                    detail("Agent's last message") { Text(message).font(.callout) }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(doc.sections ?? [], id: \.self) { SectionView(section: $0) }
            }
        }
    }

    private func detail(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.weight(.semibold))
            content()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.well, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border.opacity(0.6)))
        }
        .foregroundStyle(Theme.dim)
    }

    // MARK: Choices and answers

    private func controls(_ doc: FeedDocument, tone: Color) -> some View {
        let approve = doc.actions.first { $0.role == "approve" }
        let deny = doc.actions.first { $0.role == "deny" }
        let others = doc.actions.filter { $0.role != "approve" && $0.role != "deny" }
        return VStack(alignment: .leading, spacing: 12) {
            if request.stuck {
                HStack(alignment: .firstTextBaseline) {
                    Label("\(request.macName) isn't responding. It may be asleep.", systemImage: "moon.zzz")
                        .font(.footnote)
                        .foregroundStyle(Theme.dim)
                    Spacer()
                    Button("Dismiss") { model.dismiss(request) }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(tone)
                }
            }
            ForEach(doc.pickers ?? [], id: \.self) { picker in
                PickerRows(picker: picker, choice: binding(picker), tone: tone)
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(Theme.danger)
            }
            if let approve, let deny {
                DualSwipe(approve: approve.label, deny: deny.label, expires: item.expires, answer: answer,
                          onApprove: { send(approve.id) }, onDeny: { send(deny.id) })
            }
            HStack(spacing: 10) {
                ForEach(others, id: \.self) { action in
                    Button { send(action.id) } label: {
                        VStack(spacing: 1) {
                            Text(action.label).font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(action.role == "deny" ? Theme.danger : Theme.text)
                        .frame(width: 84, height: 52)
                        .overlay(Capsule().stroke(action.role == "deny" ? Theme.danger : Theme.border, lineWidth: 1.5))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressScale())
                    .disabled(answer != nil)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        // Nothing below but the home indicator's own margin.
        .padding(.bottom, 2)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func binding(_ picker: FeedDocument.Picker) -> Binding<String?> {
        Binding(get: { picks[picker.id] }, set: { picks[picker.id] = $0 })
    }

    /// Sends the answer, showing it at once and confirming it when the Mac accepts it. The
    /// screen holds on to this request meanwhile, so it stays put through the
    /// acknowledgement even once it has left the queue, then lets it go.
    private func send(_ action: String) {
        let approved = action == "approve"
        error = nil
        model.hold(request)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { answer = Answer(approved: approved) }
        Task {
            let failure = await model.answer(request, action: action, picks: approved ? picks.compactMapValues { $0 } : [:])
            guard failure == nil else {
                withAnimation { answer = nil }
                error = failure
                model.hold(nil)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
            UINotificationFeedbackGenerator().notificationOccurred(approved ? .success : .warning)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { answer?.confirmed = true }
            try? await Task.sleep(nanoseconds: 900_000_000)
            model.hold(nil)
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The answer, the moment it's given: a wash of its colour and its badge, dimmed with a
/// spinning ring while it goes to the Mac, then popping to full colour once the Mac accepts it.
private struct Acknowledgement: View {
    let answer: RequestView.Answer
    @State private var shown = false

    var body: some View {
        let color = answer.approved ? Theme.approve : Theme.danger
        ZStack {
            color.opacity(shown ? (answer.confirmed ? 0.28 : 0.14) : 0).ignoresSafeArea()
            VStack(spacing: 12) {
                ZStack {
                    Image(systemName: answer.approved ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 96, weight: .bold))
                        .foregroundStyle(.white, color)
                        .opacity(answer.confirmed ? 1 : 0.45)
                        .scaleEffect(answer.confirmed ? 1 : 0.85)
                        .symbolEffect(.bounce, value: answer.confirmed)
                    if !answer.confirmed { Spinner(color: color).frame(width: 128, height: 128) }
                }
                Text(answer.confirmed ? (answer.approved ? "Allowed" : "Denied") : "Sending to the Mac…")
                    .font(answer.confirmed ? .title.weight(.bold) : .headline)
                    .foregroundStyle(answer.confirmed ? Theme.text : Theme.dim)
                    .contentTransition(.opacity)
            }
            .padding(32)
            .background(Theme.well.opacity(0.92), in: RoundedRectangle(cornerRadius: 28))
            .scaleEffect(shown ? 1 : 0.6)
            .opacity(shown ? 1 : 0)
        }
        .onAppear { withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { shown = true } }
    }
}

/// A partial ring that turns while something is on its way.
struct Spinner: View {
    let color: Color
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            .rotationEffect(.degrees(turning ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true } }
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

/// A picker as rows of toggle buttons, one per facet (Allow, then For). A picker without
/// facets is a single row of its labels.
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
        }
    }

    /// One row of choices, full width: the choices say what they are without a heading.
    private func row(_ name: String, values: [(String, Bool, Bool)], pick: @escaping (String) -> Void) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(values, id: \.0) { value, on, enabled in
                    Button { pick(value) } label: {
                        Text(value)
                            .font(.subheadline.weight(on ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .foregroundStyle(on ? Theme.stripeDark : Theme.text)
                            .background(on ? tone : Theme.well, in: Capsule())
                            .overlay(Capsule().stroke(on ? tone : Theme.border, lineWidth: 1.5))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressScale())
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

/// Allow and Deny in one control: a green tick on the left and a red cross on the right, each
/// dragged all the way across to answer, so a stray touch can't do either. Touching one shows
/// at once where to drag it and hides the other; letting go short sends it back, and the hint
/// lingers a moment so it's read. The countdown to timing out sits between them. Once
/// answered, the knob rests at the far end.
struct DualSwipe: View {
    static let knob: CGFloat = 52
    private static let space = "dualSwipe"

    let approve: String
    let deny: String
    let expires: Date?
    let answer: RequestView.Answer?
    let onApprove: () -> Void
    let onDeny: () -> Void

    private enum Side { case approve, deny }
    /// The knob under a finger.
    @State private var dragging: Side?
    /// The side whose hint shows: from the first touch until shortly after letting go.
    @State private var hinting: Side?
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let travel = geo.size.width - Self.knob - 8
            let answered = answer.map { $0.approved ? Side.approve : .deny }
            let side = answered ?? dragging ?? hinting
            let progress = answered != nil ? 1 : min(1, offset / max(travel, 1))
            ZStack {
                Capsule().fill(Theme.well).overlay(Capsule().stroke(Theme.border, lineWidth: 1.5))
                if let side {
                    hint(side, travel: travel, progress: progress, answered: answered != nil)
                } else {
                    labels(width: geo.size.width)
                }
                knob(.approve, travel: travel, side: side, answered: answered)
                knob(.deny, travel: travel, side: side, answered: answered)
            }
            .animation(.easeOut(duration: 0.15), value: side)
            .coordinateSpace(name: Self.space)
        }
        .frame(height: Self.knob + 8)
        .allowsHitTesting(answer == nil)
    }

    /// While a knob is held: its trail, a dashed target at the far end, and what to do.
    private func hint(_ side: Side, travel: CGFloat, progress: CGFloat, answered: Bool) -> some View {
        let color = side == .approve ? Theme.approve : Theme.danger
        return ZStack {
            Capsule().fill(color.opacity(0.22))
                .frame(width: Self.knob + 8 + travel * progress)
                .frame(maxWidth: .infinity, alignment: side == .approve ? .leading : .trailing)
            Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                .frame(width: Self.knob, height: Self.knob)
                .padding(4)
                .frame(maxWidth: .infinity, alignment: side == .approve ? .trailing : .leading)
                .opacity(answered ? 0 : 1)
            Text("Slide all the way to \((side == .approve ? approve : deny).lowercased())")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .opacity(answered ? 0 : 1 - progress)
        }
    }

    /// At rest: each answer's word on a dim arrow pointing to the far side, the countdown
    /// between them.
    private func labels(width: CGFloat) -> some View {
        // 60% of the way from the knob to the middle.
        let arrow = (width / 2 - Self.knob / 2 - 4) * 0.6 + Self.knob / 2
        return ZStack {
            HStack(spacing: 0) {
                ArrowLabel(text: approve, color: Theme.approve, pointsRight: true).frame(width: arrow)
                Spacer(minLength: 0)
                ArrowLabel(text: deny, color: Theme.danger, pointsRight: false).frame(width: arrow)
            }
            .padding(.horizontal, Self.knob / 2 + 4)
            if let expires {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(RequestView.clock(expires.timeIntervalSince(context.date)))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Theme.dim)
                }
            }
        }
    }

    private func knob(_ which: Side, travel: CGFloat, side: Side?, answered: Side?) -> some View {
        let approving = which == .approve
        let color = approving ? Theme.approve : Theme.danger
        let moved = answered == which ? travel : dragging == which ? offset : 0
        return Circle().fill(color)
            .frame(width: Self.knob, height: Self.knob)
            .overlay(Image(systemName: approving ? "checkmark" : "xmark").font(.title3.weight(.bold)).foregroundStyle(Theme.stripeDark))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            // Only the knob itself takes touches, so each knob answers only for itself.
            .contentShape(Circle())
            // Measured against the whole control, which stays put: measured against the knob,
            // which moves as it's dragged, each step would shift the next.
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { drag in
                    if dragging == nil {
                        dragging = which
                        hinting = which
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    guard dragging == which else { return }
                    offset = min(max(0, approving ? drag.translation.width : -drag.translation.width), travel)
                }
                .onEnded { _ in
                    guard dragging == which else { return }
                    if offset >= travel - 2 { approving ? onApprove() : onDeny() }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        dragging = nil
                        offset = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        if dragging == nil { hinting = nil }
                    }
                })
            .padding(4)
            .offset(x: approving ? moved : -moved)
            .frame(maxWidth: .infinity, alignment: approving ? .leading : .trailing)
            .opacity(side == nil || side == which ? 1 : 0)
    }
}

/// A word on a dim arrow that starts under the knob and runs past the word toward the far side.
private struct ArrowLabel: View {
    let text: String
    let color: Color
    let pointsRight: Bool

    var body: some View {
        ZStack(alignment: pointsRight ? .leading : .trailing) {
            BlockArrow(pointsRight: pointsRight).fill(color.opacity(0.16)).frame(height: 45)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, DualSwipe.knob / 2 + 10)
        }
    }
}

/// A flat arrow: a bar with a pointed head at one end.
private struct BlockArrow: Shape {
    let pointsRight: Bool

    func path(in rect: CGRect) -> Path {
        let head = min(rect.height * 0.75, rect.width / 3)
        let bar = rect.insetBy(dx: 0, dy: rect.height * 0.18)
        var path = Path()
        if pointsRight {
            path.move(to: CGPoint(x: rect.minX, y: bar.minY))
            path.addLine(to: CGPoint(x: rect.maxX - head, y: bar.minY))
            path.addLine(to: CGPoint(x: rect.maxX - head, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - head, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - head, y: bar.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: bar.maxY))
        } else {
            path.move(to: CGPoint(x: rect.maxX, y: bar.minY))
            path.addLine(to: CGPoint(x: rect.minX + head, y: bar.minY))
            path.addLine(to: CGPoint(x: rect.minX + head, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX + head, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + head, y: bar.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: bar.maxY))
        }
        path.closeSubpath()
        return path
    }
}

/// Where the header's robot and key icons, and the agent's lines, landed, so a line can join
/// the icons with its question mark below the agent's lines.
private struct IconBounds: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A dashed line from the agent down to the item, with a question mark halfway: it asks for it.
private struct AsksFor: View {
    let tone: Color
    let from: CGPoint
    let to: CGPoint
    /// How far down the line the question mark sits.
    let mark: CGFloat

    var body: some View {
        let mid = CGPoint(x: from.x + (to.x - from.x) * (mark - from.y) / max(to.y - from.y, 1), y: mark)
        ZStack {
            Path { path in
                path.move(to: from)
                path.addLine(to: to)
            }
            .stroke(tone.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 4]))
            Text("?")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(tone)
                .frame(width: 17, height: 17)
                // Filled with the background, so the dashes stop at the ring.
                .background(Theme.background, in: Circle())
                .overlay(Circle().stroke(tone, lineWidth: 1.5))
                .position(mid)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
