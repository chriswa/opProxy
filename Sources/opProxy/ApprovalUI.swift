import AppKit
import OpProxyCore

/// Shows one request at a time in a panel with everything known about it. Only a click on
/// Allow with the mouse or trackpad approves (`GenuineClickButton`); Deny or the timeout denies.
final class DialogApprover: LocalApprover {
    static let timeout: TimeInterval = 300

    /// Requests waiting behind the one on screen; only one dialog is ever shown.
    private var queue: [(ApprovalPrompt, (Decision) -> Void)] = []
    private var current: ApprovalSession?
    var onCountdown: ((DialogKey, Date) -> Void)?

    func requestApproval(_ prompt: ApprovalPrompt, completion: @escaping (Decision) -> Void) {
        DispatchQueue.main.async { [self] in
            queue.append((prompt, completion))
            showNext()
            current?.setWaiting(queue.count)
        }
    }

    /// Keys whose requesters have all disconnected, for dialogs not yet on screen.
    private var abandoned: Set<DialogKey> = []

    func requestersLeft(_ key: DialogKey) {
        DispatchQueue.main.async { [self] in
            if current?.prompt.key == key { current?.markAbandoned() } else { abandoned.insert(key) }
        }
    }

    func dismiss(_ key: DialogKey) {
        DispatchQueue.main.async { [self] in
            abandoned.remove(key)
            if current?.prompt.key == key {
                current?.dismiss()  // ends the session, which shows the next
            } else {
                queue.removeAll { $0.0.key == key }
                current?.setWaiting(queue.count)
            }
        }
    }

    private func showNext() {
        guard current == nil, !queue.isEmpty else { return }
        let (prompt, completion) = queue.removeFirst()
        let session = ApprovalSession(prompt: prompt, timeout: Self.timeout) { [self] decision in
            // nil: dismissed because it was answered elsewhere.
            if let decision { completion(decision) }
            current = nil
            showNext()
        }
        current = session
        let deadline = session.begin()
        session.setWaiting(queue.count)
        if abandoned.remove(prompt.key) != nil { session.markAbandoned() }
        onCountdown?(prompt.key, deadline)
    }
}

/// One dialog's lifetime. Must be used on the main thread.
private final class ApprovalSession: NSObject, ApprovalViewActions {
    let prompt: ApprovalPrompt
    let timeout: TimeInterval
    let onDecision: (Decision?) -> Void
    private var panel: NSPanel?
    private var view: ApprovalView?
    private var decided = false
    private var ticker: Timer?
    private var retainSelf: ApprovalSession?

    init(prompt: ApprovalPrompt, timeout: TimeInterval, onDecision: @escaping (Decision?) -> Void) {
        self.prompt = prompt
        self.timeout = timeout
        self.onDecision = onDecision
    }

    /// Returns when the countdown runs out.
    func begin() -> Date {
        retainSelf = self
        let view = ApprovalView(prompt: prompt, actions: self)
        self.view = view
        let panel = GuardedPanel(contentRect: NSRect(origin: .zero, size: view.fittingSize),
                                 styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        Caution.style(panel)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        panel.setContentSize(view.fittingSize)
        if let screen = NSScreen.main?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 40))
        }
        // Take focus so the request can't be missed. GuardedPanel ignores the keyboard, so
        // typing that lands here does nothing.
        panel.presentForAnswer()
        panel.ignoreMouse(for: GuardedPanel.clickGuard)
        self.panel = panel
        let deadline = Date().addingTimeInterval(timeout)
        view.setRemaining(Int(timeout))
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { finish(.timedOut) } else { self.view?.setRemaining(Int(left.rounded(.up))) }
        }
        return deadline
    }

    func allow() {
        guard !decided, let view else { return }
        finish(.approved(.mac, view.selectedScope))
    }

    func deny() { finish(.denied) }

    /// Answered elsewhere: closes without a decision of its own.
    func dismiss() { finish(nil) }

    func setWaiting(_ count: Int) { view?.setWaiting(count) }

    func markAbandoned() { view?.showAbandoned() }

    func openSession() {
        if let url = prompt.requester.label?.openURL { NSWorkspace.shared.open(url) }
    }

    private func finish(_ decision: Decision?) {
        guard !decided else { return }
        decided = true
        ticker?.invalidate()
        panel?.orderOut(nil)
        panel = nil
        onDecision(decision)
        retainSelf = nil
    }
}

protocol ApprovalViewActions: AnyObject {
    func allow()
    func deny()
    func openSession()
}

/// The panel's content. Separate from the session so it can be rendered for previews.
final class ApprovalView: NSView {
    static let width: CGFloat = 620
    private static let inner = width - 48

    private weak var actions: ApprovalViewActions?
    private let allowButton = GenuineClickButton(title: "Allow", target: nil, action: nil)
    private let denyButton = NSButton(title: "Deny", target: nil, action: nil)
    private let note = NSTextField(wrappingLabelWithString: "")
    private let waitingLabel = NSTextField(labelWithString: "")
    private let durationControl = NSSegmentedControl()
    /// Agents only: which agents a lasting approval covers.
    private let reachControl = NSSegmentedControl()
    private var options: [ApprovalOption] = []
    /// Agents pick a duration and a reach; terminals pick straight from `options`.
    private var isAgent = false
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let abandonedNote = NSTextField(wrappingLabelWithString:
        "The agent stopped waiting. Allowing still lets its retry through.")
    private let copyButton = NSButton()
    /// The dialog as plain text, one entry per block, appended as each block is built.
    private var transcript: [String] = []

    init(prompt: ApprovalPrompt, actions: ApprovalViewActions?) {
        self.actions = actions
        super.init(frame: .zero)
        wantsLayer = true
        // One look regardless of system appearance: dark base so text colors stay legible.
        appearance = NSAppearance(named: .darkAqua)
        let stripe = HazardStripe()
        stripe.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stripe)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stripe.leadingAnchor.constraint(equalTo: leadingAnchor),
            stripe.trailingAnchor.constraint(equalTo: trailingAnchor),
            stripe.topAnchor.constraint(equalTo: topAnchor),
            stripe.heightAnchor.constraint(equalToConstant: Caution.stripeHeight),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: stripe.bottomAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        let headerViews = header(prompt)
        headerViews.forEach { stack.addArrangedSubview($0) }
        for view in headerViews.dropLast() { stack.setCustomSpacing(4, after: view) }
        stack.setCustomSpacing(10, after: headerViews[0])
        stack.setCustomSpacing(10, after: headerViews[2])
        stack.addArrangedSubview(requestCard(prompt))
        switch prompt.requester {
        case .agent(let agent):
            if let tool = agent.caller.toolCommand {
                stack.addArrangedSubview(section("Agent's shell command", prompt.hidingSecrets(tool), mono: true, maxLines: 8))
            }
            if let message = agent.lastMessage {
                stack.addArrangedSubview(section("Agent's last message", prompt.hidingSecrets(message), mono: false, maxLines: 6))
            }
        case .terminal(let terminal):
            stack.addArrangedSubview(section("Process chain (nearest first)",
                                             prompt.hidingSecrets(terminal.info.chain.joined(separator: "\n")), mono: true, maxLines: 8))
        }
        stack.addArrangedSubview(metadata(prompt))
        stack.addArrangedSubview(footer(prompt))
        stack.arrangedSubviews.forEach { $0.widthAnchor.constraint(lessThanOrEqualToConstant: Self.inner).isActive = true }
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Caution.background.cgColor }

    /// The Deny button counts down to the automatic denial; red for the last 20 seconds.
    func setRemaining(_ seconds: Int) {
        let color = seconds <= 20 ? Caution.danger : Caution.text
        denyButton.attributedTitle = NSAttributedString(string: "Deny · \(seconds)s", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: seconds <= 20 ? .bold : .medium),
            .foregroundColor: color])
    }

    func showAbandoned() {
        abandonedNote.isHidden = false
    }

    /// "2 more waiting" when other requests are queued behind this one.
    func setWaiting(_ count: Int) {
        waitingLabel.stringValue = "\(count) more waiting"
        waitingLabel.isHidden = count == 0
    }

    /// Says why a click didn't count.
    func showNote(_ text: String) {
        note.stringValue = text
        note.isHidden = false
    }

    // MARK: Sections

    /// Who is asking, then the item, both in the largest type: the two things to check
    /// before touching.
    private func header(_ prompt: ApprovalPrompt) -> [NSView] {
        let kicker = NSTextField(labelWithString: "⚠︎  1PASSWORD SECURITY APPROVAL")
        kicker.font = .systemFont(ofSize: 11, weight: .heavy)
        kicker.textColor = Caution.accent
        waitingLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        waitingLabel.textColor = Caution.accent
        waitingLabel.isHidden = true
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy dialog text")
        copyButton.toolTip = "Copy this request as text"
        copyButton.isBordered = false
        copyButton.contentTintColor = Caution.secondary
        copyButton.target = self
        copyButton.action = #selector(copyTranscript)
        let top = NSStackView(views: [kicker, NSView(), waitingLabel, copyButton])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true

        let requester = prompt.requester
        let who = Self.headline(NSAttributedString(string: requester.headline, attributes: [
            .font: NSFont.systemFont(ofSize: Self.headlineSize + 4, weight: .heavy), .foregroundColor: Caution.text]))

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        var whereParts: [String]
        switch requester {
        case .agent(let a):
            // The kind is already in the headline when nothing named the agent.
            whereParts = (a.label?.name != nil ? [requester.kind] : [])
                + [a.label?.title.map { "in “\($0)”" } ?? "in an untitled session"]
        case .terminal(let t):
            whereParts = ["in a terminal tab"] + [t.info.tty, t.label?.title.map { "“\($0)”" }].compactMap { $0 }
        }
        let whereText = whereParts.joined(separator: " · ")
        let session = NSTextField(labelWithString: whereText)
        session.font = .systemFont(ofSize: 13)
        session.textColor = Caution.secondary
        session.lineBreakMode = .byTruncatingTail
        session.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(session)
        if requester.label?.openURL != nil {
            let link = NSButton(title: "Open ↗", target: self, action: #selector(openSession))
            link.isBordered = false
            link.contentTintColor = Caution.link
            link.font = .systemFont(ofSize: 13)
            row.addArrangedSubview(link)
        }

        let wants = Self.label(Self.verb(prompt.subject), size: 13)
        let target = prompt.target
        let itemText = NSMutableAttributedString(string: target.vaultName, attributes: [
            .font: NSFont.systemFont(ofSize: Self.headlineSize, weight: .medium), .foregroundColor: Caution.text])
        itemText.append(NSAttributedString(string: " / ", attributes: [
            .font: NSFont.systemFont(ofSize: Self.headlineSize, weight: .light), .foregroundColor: Caution.secondary]))
        itemText.append(NSAttributedString(string: target.title, attributes: [
            .font: NSFont.systemFont(ofSize: Self.headlineSize, weight: .heavy), .foregroundColor: Caution.accent]))
        let item = Self.headline(itemText)

        transcript.append([kicker.stringValue, who.stringValue, whereText, wants.stringValue, target.label]
            .joined(separator: "\n"))
        return [top, who, row, wants, item]
    }

    static let headlineSize: CGFloat = 28

    private static func verb(_ subject: Subject) -> String {
        guard case .write(let w) = subject else { return "wants access to" }
        switch w.kind {
        case .create: return "wants to create"
        case .edit: return "wants to edit"
        case .delete(archive: false): return "wants to delete"
        case .delete(archive: true): return "wants to archive"
        }
    }

    private static func headline(_ text: NSAttributedString) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.attributedStringValue = text
        field.isSelectable = true
        field.preferredMaxLayoutWidth = inner
        return field
    }

    private func requestCard(_ prompt: ApprovalPrompt) -> NSView {
        let grid = NSGridView()
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        var lines: [String] = []
        defer { transcript.append(lines.joined(separator: "\n")) }
        func row(_ label: String, _ field: NSTextField) {
            grid.addRow(with: [Self.label(label, size: 13), field])
            lines.append("\(label): \(field.stringValue)")
        }
        row("Request", Self.value(prompt.action, size: 14, weight: .medium))
        for detail in prompt.details {
            switch detail.style {
            case .normal: row(detail.label, Self.value(detail.value, size: 14, weight: .medium))
            case .placeholder: row(detail.label, Self.value(detail.value, size: 14, color: Caution.secondary))
            }
        }
        if !prompt.target.itemId.isEmpty {
            row("Item ID", Self.value(prompt.target.itemId, size: 12, mono: true, color: Caution.secondary))
        }
        row("Vault ID", Self.value(prompt.target.vaultId, size: 12, mono: true, color: Caution.secondary))
        row("Command", Self.value(prompt.commandLine, size: 12, mono: true))
        Self.styleLabelColumn(grid)
        return CardView(content: grid, width: Self.inner, inset: NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 14))
    }

    private func metadata(_ prompt: ApprovalPrompt) -> NSView {
        let grid = NSGridView()
        grid.rowSpacing = 3
        grid.columnSpacing = 12
        var lines: [String] = []
        defer { transcript.append(lines.joined(separator: "\n")) }
        func row(_ label: String, _ value: String) {
            grid.addRow(with: [Self.label(label, size: 11), Self.value(value, size: 11, mono: true, color: Caution.secondary)])
            lines.append("\(label): \(value)")
        }
        switch prompt.requester {
        case .agent(let a):
            row("Session ID", a.session.sessionId)
            row("Agent process", "\(a.session.agent.displayName) · PID \(a.agentPid)")
            row("Requested by", "PID \(prompt.peerPid)")
            row("Directory", prompt.request.cwd)
            if let via = a.caller.viaProcess { row("Called by", String(prompt.hidingSecrets(via).prefix(300))) }
        case .terminal(let t):
            row("Terminal", t.info.app + (t.info.tty.map { " · \($0)" } ?? ""))
            row("Tab session", "Unix session \(t.info.sid)")
            row("Requested by", "PID \(prompt.peerPid)")
            row("Directory", prompt.request.cwd)
        }
        Self.styleLabelColumn(grid)
        return grid
    }

    /// What Allow will grant; chosen before clicking it.
    var selectedScope: ApprovalScope {
        let i = max(0, durationControl.selectedSegment)
        guard isAgent else { return options[i].scope }
        guard i > 0 else { return .once }
        return .lasting(ApprovalLifetime.allCases[i - 1], ApprovalReach.allCases[max(0, reachControl.selectedSegment)])
    }

    /// Shows what the current choice grants; the widest grant is said in red.
    private func scopeChanged() {
        let scope = selectedScope
        reachControl.isEnabled = scope != .once
        guard let option = options.first(where: { $0.scope == scope }) else { return }
        hint.stringValue = option.hint
        hint.textColor = scope == .lasting(.forever, .allAgents) ? Caution.danger : Caution.secondary
    }

    private static func segments(_ control: NSSegmentedControl, _ labels: [String], selected: Int) {
        control.segmentCount = labels.count
        for (i, label) in labels.enumerated() { control.setLabel(label, forSegment: i) }
        control.trackingMode = .selectOne
        control.selectedSegment = selected
        control.controlSize = .large
    }

    private func footer(_ prompt: ApprovalPrompt) -> NSView {
        let defaultIndex: Int
        (options, defaultIndex) = ApprovalOptions.for(prompt.requester, write: prompt.isWrite)
        if case .agent = prompt.requester, !prompt.isWrite { isAgent = true }
        let choices = NSGridView()
        choices.rowSpacing = 6
        choices.columnSpacing = 10
        choices.rowAlignment = .lastBaseline
        if isAgent {
            Self.segments(durationControl, ["Once"] + ApprovalLifetime.allCases.map(\.label), selected: 0)
            Self.segments(reachControl, ApprovalReach.allCases.map(\.label), selected: 0)
            choices.addRow(with: [Self.label("Allow", size: 13), durationControl])
            choices.addRow(with: [Self.label("For", size: 13), reachControl])
        } else {
            Self.segments(durationControl, options.map(\.label), selected: defaultIndex)
            choices.addRow(with: [Self.label("Allow", size: 13), durationControl])
        }
        // A write offers only Once: nothing to choose.
        choices.isHidden = options.count == 1
        for control in [durationControl, reachControl] {
            control.target = self
            control.action = #selector(choiceChanged)
        }
        choices.column(at: 0).xPlacement = .trailing
        // Hug the controls, so the grid doesn't spread across the footer.
        choices.setContentHuggingPriority(.required, for: .horizontal)
        hint.font = .systemFont(ofSize: 11)
        scopeChanged()
        note.font = .systemFont(ofSize: 11, weight: .semibold)
        note.textColor = Caution.danger
        note.isHidden = true
        abandonedNote.font = .systemFont(ofSize: 11, weight: .semibold)
        abandonedNote.textColor = Caution.accent
        abandonedNote.isHidden = true
        let text = NSStackView(views: [choices, abandonedNote, hint, note])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.setCustomSpacing(8, after: choices)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for (button, action) in [(denyButton, #selector(deny)), (allowButton, #selector(allow))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.controlSize = .large
        }
        allowButton.attributedTitle = NSAttributedString(string: "Allow", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: Caution.accent])
        allowButton.onSynthetic = { [weak self] pid in
            self?.showNote("That click came from another app (PID \(pid)), not your mouse or trackpad, so it didn't count.")
        }

        let row = NSStackView(views: [text, NSView(), denyButton, allowButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
        return row
    }

    @objc private func choiceChanged() { scopeChanged() }

    #if OPPROXY_TESTING
    /// Previews: shows the footer as if `lifetime` and `reach` were chosen.
    func choose(_ lifetime: ApprovalLifetime, _ reach: ApprovalReach) {
        durationControl.selectedSegment = 1 + ApprovalLifetime.allCases.firstIndex(of: lifetime)!
        reachControl.selectedSegment = ApprovalReach.allCases.firstIndex(of: reach)!
        scopeChanged()
    }
    #endif
    @objc private func allow() { actions?.allow() }
    @objc private func deny() { actions?.deny() }
    @objc private func openSession() { actions?.openSession() }

    var copyText: String { transcript.joined(separator: "\n\n") }

    /// Puts the whole request on the pasteboard, for handing to an agent. Approves nothing.
    @objc private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy dialog text")
        }
    }

    // MARK: Pieces

    private func section(_ title: String, _ text: String, mono: Bool, maxLines: Int) -> NSView {
        transcript.append("\(title):\n\(text)")
        let label = Self.label(title, size: 11, weight: .semibold)
        let stack = NSStackView(views: [label, Self.textBlock(text, mono: mono, maxLines: maxLines)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        return stack
    }

    private static func label(_ s: String, size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = Caution.secondary
        return l
    }

    private static func value(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false,
                              color: NSColor = Caution.text) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.isSelectable = true
        f.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.preferredMaxLayoutWidth = valueColumnWidth
        return f
    }

    static let labelColumnWidth: CGFloat = 112

    /// Width left for values beside the label column inside a card.
    static let valueColumnWidth: CGFloat = inner - labelColumnWidth - 12 - 14

    /// Right-aligned labels in a fixed-width column, so every grid lines up; values get the
    /// rest, so wrapping labels know their width.
    private static func styleLabelColumn(_ grid: NSGridView) {
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = labelColumnWidth
        grid.column(at: 1).width = valueColumnWidth
        grid.rowAlignment = .firstBaseline
    }

    /// Selectable text sized to its wrapped content, scrolling beyond `maxLines`.
    private static func textBlock(_ s: String, mono: Bool, maxLines: Int) -> NSView {
        let font: NSFont = mono ? .monospacedSystemFont(ofSize: 11.5, weight: .regular) : .systemFont(ofSize: 12.5)
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.string = s
        text.font = font
        text.textColor = Caution.text
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 8, height: 7)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true

        // Measure the wrapped text at the block's real width.
        let container = NSTextContainer(size: NSSize(width: inner - 16 - 2 * text.textContainer!.lineFragmentPadding,
                                                     height: .greatestFiniteMagnitude))
        let layout = NSLayoutManager()
        let storage = NSTextStorage(string: s, attributes: [.font: font])
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let lineHeight = layout.defaultLineHeight(for: font)
        let contentHeight = layout.usedRect(for: container).height
        let height = min(contentHeight, lineHeight * CGFloat(maxLines)) + 14

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: ceil(height)).isActive = true
        return CardView(content: scroll, width: inner, inset: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
                        fill: Caution.well)
    }
}

/// Only deliberate mouse input may act on an approval: keystrokes are dropped (except ⌘C, to
/// copy text), and clicks are ignored briefly after the panel appears, since a click already
/// under way can land on a button that just popped up beneath the pointer.
final class GuardedPanel: NSPanel {
    static let clickGuard: TimeInterval = 0.5
    private var mouseArmedAt = Date.distantPast

    func ignoreMouse(for interval: TimeInterval) {
        mouseArmedAt = Date().addingTimeInterval(interval)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown, .keyUp:
            let copy = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                && event.charactersIgnoringModifiers == "c"
            if copy { super.sendEvent(event) }
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if Date() >= mouseArmedAt { super.sendEvent(event) }
        default:
            super.sendEvent(event)
        }
    }

    // Esc and ⌘. arrive as commands rather than key events in some paths; ignore them too.
    override func cancelOperation(_ sender: Any?) {}
}

/// A rounded, bordered background sized by Auto Layout around its content.
final class CardView: NSView {
    private let fill: NSColor

    init(content: NSView, width: CGFloat, inset: NSEdgeInsets, fill: NSColor = Caution.card) {
        self.fill = fill
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset.left),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset.right),
            content.topAnchor.constraint(equalTo: topAnchor, constant: inset.top),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset.bottom),
        ])
        if content is NSScrollView {
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset.right).isActive = true
        }
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = Caution.border.cgColor
    }
}

/// The approval panel's fixed caution palette: it should never look like an ordinary dialog.
enum Caution {
    static let background = NSColor(srgbRed: 0.12, green: 0.105, blue: 0.08, alpha: 1)
    static let card = NSColor(srgbRed: 0.17, green: 0.15, blue: 0.11, alpha: 1)
    static let well = NSColor(srgbRed: 0.08, green: 0.07, blue: 0.055, alpha: 1)
    static let border = NSColor(srgbRed: 0.96, green: 0.77, blue: 0.0, alpha: 0.35)
    static let accent = NSColor(srgbRed: 0.98, green: 0.80, blue: 0.08, alpha: 1)
    static let text = NSColor(srgbRed: 0.97, green: 0.95, blue: 0.91, alpha: 1)
    static let secondary = NSColor(srgbRed: 0.74, green: 0.70, blue: 0.62, alpha: 1)
    static let danger = NSColor(srgbRed: 1.0, green: 0.42, blue: 0.30, alpha: 1)
    static let link = NSColor(srgbRed: 0.45, green: 0.72, blue: 1.0, alpha: 1)
    static let stripeHeight: CGFloat = 14

    /// Hidden title and window buttons: the hazard stripe is the top edge, and the only ways
    /// out are Allow, Deny, or the timeout.
    static func style(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = background
        window.appearance = NSAppearance(named: .darkAqua)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
    }
}

/// Black and yellow diagonal hazard stripes.
final class HazardStripe: NSView {
    var dark = NSColor(srgbRed: 0.07, green: 0.06, blue: 0.05, alpha: 1)
    var light = Caution.accent

    override func draw(_ dirtyRect: NSRect) {
        dark.setFill()
        bounds.fill()
        light.setFill()
        let band: CGFloat = 12
        var x = -bounds.height
        while x < bounds.width + bounds.height {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x + band, y: 0))
            path.line(to: NSPoint(x: x + band + bounds.height, y: bounds.height))
            path.line(to: NSPoint(x: x + bounds.height, y: bounds.height))
            path.close()
            path.fill()
            x += band * 2
        }
    }
}

/// A button only the mouse or trackpad can press. Another app with Accessibility permission
/// can post clicks or press a button through the accessibility API; neither counts here.
/// Posted clicks carry the poster's process ID, where the hardware's carry 0: the same test
/// the window server applies to clicks on macOS's own security prompts (sender 0 or self).
final class GenuineClickButton: NSButton {
    /// Told the posting process's ID when a click came from another app.
    var onSynthetic: ((Int64) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if let source = Self.poster(of: event) {
            onSynthetic?(source)
            return
        }
        super.mouseDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool { false }

    /// The process that posted `event`, if it wasn't the hardware (or this app); nil for a
    /// genuine click. -1 when there's no click at all, as for a press through accessibility.
    static func poster(of event: NSEvent?) -> Int64? {
        guard let event, [.leftMouseDown, .leftMouseUp].contains(event.type) else { return -1 }
        let source = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
        return source == 0 || source == Int64(getpid()) ? nil : source
    }
}

func shellQuote(_ s: String) -> String {
    // ‹hidden› stands in for a value the command writes; it never needs quoting.
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=@,+%‹›"))
    if !s.isEmpty, s.unicodeScalars.allSatisfy(safe.contains) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// For tests: decides without UI, per `OPPROXY_TEST_APPROVER`. Logs what the dialog would
/// show so tests can assert on it.
final class ScriptedApprover: LocalApprover {
    let decision: Decision
    let delay: TimeInterval
    let log: Log
    var onCountdown: ((DialogKey, Date) -> Void)?

    init(decision: Decision, delay: TimeInterval, log: Log) {
        self.decision = decision
        self.delay = delay
        self.log = log
    }

    func requestApproval(_ prompt: ApprovalPrompt, completion: @escaping (Decision) -> Void) {
        let summary: String
        switch prompt.subject {
        case .read(let r): summary = r.summary(prompt.target)
        case .write(let w): summary = w.summary(prompt.target)
        }
        let shown: [String: Any] = [
            "summary": summary,
            "item": prompt.target.title,
            "vault": prompt.target.vaultName,
            "itemId": prompt.target.itemId,
            "details": prompt.details.map { "\($0.label)=\($0.value)" },
            "command": prompt.commandLine,
            "options": ApprovalOptions.for(prompt.requester, write: prompt.isWrite).options.map(\.id),
            "headline": prompt.requester.headline,
            "requester": prompt.requester.name,
            "label": prompt.requester.labelTitle ?? NSNull(),
        ]
        var fields = shown
        switch prompt.requester {
        case .agent(let a):
            fields["toolCommand"] = a.caller.toolCommand.map(prompt.hidingSecrets) ?? NSNull()
            fields["via"] = a.caller.viaProcess.map(prompt.hidingSecrets) ?? NSNull()
            fields["lastMessage"] = a.lastMessage.map { String(prompt.hidingSecrets($0).prefix(80)) } ?? NSNull()
        case .terminal(let t):
            fields["chain"] = t.info.chain.map { $0.split(separator: " ", maxSplits: 2).last.map(String.init) ?? $0 }
        }
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) {
            log.write("dialog: " + String(decoding: data, as: UTF8.self))
        }
        // As if its dialog were on screen at once, counting down to the scripted answer.
        onCountdown?(prompt.key, Date().addingTimeInterval(delay))
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [decision] in completion(decision) }
    }

    func requestersLeft(_ key: DialogKey) {}

    /// The scripted answer still arrives later; `FanoutApprover` ignores it.
    func dismiss(_ key: DialogKey) {}
}
