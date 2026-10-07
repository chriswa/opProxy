import FeedProtocol
import SwiftUI

/// One request, as its document describes it, with the choices it offers.
struct RequestView: View {
    @EnvironmentObject private var model: FeedModel
    let id: String
    @State private var picks: [String: String] = [:]
    @State private var sending = false
    @State private var error: String?
    @State private var answered: String?

    var body: some View {
        if let item = model.items.first(where: { $0.id == id }), let doc = item.parsed {
            content(item, doc)
        } else {
            ContentUnavailableView(model.removed[id]?.note ?? "No longer pending", systemImage: "checkmark.circle",
                                   description: Text(answered ?? model.removed[id]?.item.parsed?.title ?? ""))
        }
    }

    private func content(_ item: FeedItem, _ doc: FeedDocument) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    if let kicker = doc.kicker {
                        Text(kicker.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(tone(doc))
                    }
                    Text(doc.title).font(.largeTitle.weight(.bold))
                    if let subtitle = doc.subtitle { Text(subtitle).font(.title3).foregroundStyle(.secondary) }
                    if let expires = item.expires {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("Times out in \(max(0, Int(expires.timeIntervalSince(context.date))))s")
                                .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                if let notice = doc.notice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                ForEach(doc.sections ?? [], id: \.self) { SectionView(section: $0) }
                ForEach(doc.pickers ?? [], id: \.self) { picker in pickerView(picker) }
                if let error { Text(error).foregroundStyle(.red) }
                actions(item, doc)
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            for picker in doc.pickers ?? [] where picks[picker.id] == nil {
                picks[picker.id] = picker.default ?? picker.options.first?.id
            }
        }
    }

    private func pickerView(_ picker: FeedDocument.Picker) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label = picker.label { Text(label).font(.headline) }
            ForEach(picker.options, id: \.self) { option in
                Button {
                    picks[picker.id] = option.id
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: picks[picker.id] == option.id ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label).foregroundStyle(.primary)
                            if let hint = option.hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func actions(_ item: FeedItem, _ doc: FeedDocument) -> some View {
        let deny = doc.actions.filter { $0.role != "approve" }
        let approve = doc.actions.first { $0.role == "approve" }
        VStack(spacing: 12) {
            if let approve {
                // What approving grants, said by the app itself beside the control.
                let chosen = (doc.pickers ?? []).compactMap { p in p.options.first { $0.id == picks[p.id] }?.label }
                Text(([doc.confirm] + chosen).joined(separator: " · ")).font(.callout.weight(.medium))
                SlideToApprove(label: approve.label, disabled: sending) { send(item, approve.id) }
            }
            ForEach(deny, id: \.self) { action in
                Button(role: action.role == "deny" ? .destructive : nil) { send(item, action.id) } label: {
                    Text(action.label).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(sending)
            }
        }
        .padding(.top, 8)
    }

    private func send(_ item: FeedItem, _ action: String) {
        sending = true
        error = nil
        Task {
            let failure = await model.answer(item, action: action, picks: action == "approve" ? picks : [:])
            sending = false
            if let failure { error = failure } else { answered = action == "approve" ? "Approved" : "Denied" }
        }
    }

    private func tone(_ doc: FeedDocument) -> Color {
        switch doc.tone {
        case "danger": return .red
        case "caution": return .orange
        default: return .teal
        }
    }
}

private struct SectionView: View {
    let section: FeedDocument.Section

    var body: some View {
        if section.rows != nil || section.text != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let label = section.label { Text(label).font(.headline) }
                if let rows = section.rows {
                    ForEach(rows, id: \.self) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                            Text(row.value).font(row.mono == true ? .callout.monospaced() : .callout).textSelection(.enabled)
                        }
                    }
                } else if let text = section.text {
                    Text(text).font(section.mono == true ? .callout.monospaced() : .callout).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

/// Approving takes a deliberate drag all the way across, so a stray tap can't approve.
struct SlideToApprove: View {
    let label: String
    let disabled: Bool
    let action: () -> Void
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let knob: CGFloat = 52
            let travel = geo.size.width - knob - 8
            ZStack(alignment: .leading) {
                Capsule().fill(Color.teal.opacity(0.18))
                Text("Slide to \(label.lowercased())").font(.headline).foregroundStyle(.teal).frame(maxWidth: .infinity)
                Circle().fill(Color.teal).frame(width: knob, height: knob)
                    .overlay(Image(systemName: "chevron.right.2").foregroundStyle(.white).font(.headline))
                    .offset(x: 4 + offset)
                    .gesture(DragGesture()
                        .onChanged { offset = min(max(0, $0.translation.width), travel) }
                        .onEnded { _ in
                            if offset >= travel - 2 { action() }
                            withAnimation(.spring) { offset = 0 }
                        })
            }
            .opacity(disabled ? 0.4 : 1)
            .allowsHitTesting(!disabled)
        }
        .frame(height: 60)
    }
}
