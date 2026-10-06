import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import OpProxyCore

/// Shows one request at a time in a panel with everything known about it, listening for
/// Touch ID the moment it appears: the fingerprint glyph is embedded in the panel
/// (LAAuthenticationView), so there's no system sheet and no button to click. Touch ID also
/// authorizes signing the approval. Deny or the timeout denies.
final class DialogApprover: LocalApprover {
    static let timeout: TimeInterval = 110

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
    private var context: LAContext?
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
        let context = LAContext()
        let view = ApprovalView(prompt: prompt, actions: self, authContext: context)
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
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.ignoreMouse(for: GuardedPanel.clickGuard)
        self.panel = panel
        listen(with: context)
        let deadline = Date().addingTimeInterval(timeout)
        view.setRemaining(Int(timeout))
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { finish(.timedOut) } else { self.view?.setRemaining(Int(left.rounded(.up))) }
        }
        return deadline
    }

    /// Evaluating the approval key's own access control means this Touch ID also authorizes
    /// signing the approval. The embedded view bound to `context` shows the prompt inline.
    private func listen(with context: LAContext) {
        self.context = context
        context.evaluateAccessControl(EnclaveSigner.accessControl(), operation: .useKeySign,
                                      localizedReason: prompt.touchIDReason) { ok, error in
            DispatchQueue.main.async { [self] in
                guard !decided else { return }
                if ok {
                    finish(.approved(.touchID(context), view?.selectedScope ?? .once))
                } else {
                    let reason = (error as? LAError).map(Self.describe) ?? "Touch ID didn't approve"
                    view?.showRetry(note: "\(reason). Try again, or deny.")
                }
            }
        }
    }

    func retry() {
        guard !decided else { return }
        let context = LAContext()
        view?.replaceAuthContext(context)
        listen(with: context)
    }

    private static func describe(_ error: LAError) -> String {
        switch error.code {
        case .authenticationFailed: return "Fingerprint not recognized"
        case .userCancel, .systemCancel, .appCancel: return "Touch ID was cancelled"
        case .biometryLockout: return "Touch ID is locked out"
        default: return "Touch ID didn't approve"
        }
    }

    func deny() { finish(.denied) }

    /// Answered elsewhere: closes without a decision of its own.
    func dismiss() { finish(nil) }

    func setWaiting(_ count: Int) { view?.setWaiting(count) }

    func markAbandoned() { view?.showAbandoned() }

    func openSession() {
        if let url = prompt.requester.spacetermURL { NSWorkspace.shared.open(url) }
    }

    private func finish(_ decision: Decision?) {
        guard !decided else { return }
        decided = true
        ticker?.invalidate()
        // An approving context stays valid until the daemon has signed with it.
        if case .approved = decision {} else { context?.invalidate() }
        panel?.orderOut(nil)
        panel = nil
        onDecision(decision)
        retainSelf = nil
    }
}

protocol ApprovalViewActions: AnyObject {
    func retry()
    func deny()
    func openSession()
}

/// The panel's content. Separate from the session so it can be rendered for previews.
final class ApprovalView: NSView {
    static let width: CGFloat = 620
    private static let inner = width - 48

    private weak var actions: ApprovalViewActions?
    private let retryButton = NSButton(title: "Try Again", target: nil, action: nil)
    private let denyButton = NSButton(title: "Deny", target: nil, action: nil)
    private let note = NSTextField(wrappingLabelWithString: "")
    private let authSlot = NSView()
    private let waitingLabel = NSTextField(labelWithString: "")
    private let durationControl = NSSegmentedControl()
    private var durations: [ApprovalOption] = []
    private var defaultDuration = 0
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let abandonedNote = NSTextField(wrappingLabelWithString:
        "The agent stopped waiting. Approving still lets its retry through.")
    private let copyButton = NSButton()
    /// The dialog as plain text, one entry per block, appended as each block is built.
    private var transcript: [String] = []

    /// `authContext` drives the embedded Touch ID glyph; nil draws a static one (previews).
    init(prompt: ApprovalPrompt, actions: ApprovalViewActions?, authContext: LAContext?) {
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
        for view in headerViews.dropLast() { stack.setCustomSpacing(5, after: view) }
        stack.addArrangedSubview(requestCard(prompt))
        switch prompt.requester {
        case .agent(let agent):
            if let tool = agent.caller.toolCommand {
                stack.addArrangedSubview(section("Agent's shell command", tool, mono: true, maxLines: 8))
            }
            if let message = agent.lastMessage {
                stack.addArrangedSubview(section("Agent's last message", message, mono: false, maxLines: 6))
            }
        case .terminal(let terminal):
            stack.addArrangedSubview(section("Process chain (nearest first)", terminal.info.chain.joined(separator: "\n"),
                                             mono: true, maxLines: 8))
        }
        stack.addArrangedSubview(metadata(prompt))
        stack.addArrangedSubview(footer(prompt))
        replaceAuthContext(authContext)
        stack.arrangedSubviews.forEach { $0.widthAnchor.constraint(lessThanOrEqualToConstant: Self.inner).isActive = true }
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Caution.background.cgColor }

    static let glyphSize: CGFloat = 38

    /// Puts a Touch ID glyph for `context` in the footer and hides any retry state.
    func replaceAuthContext(_ context: LAContext?) {
        authSlot.subviews.forEach { $0.removeFromSuperview() }
        let glyph: NSView
        if let context {
            glyph = LAAuthenticationView(context: context, controlSize: .regular)
        } else {
            let image = NSImageView(image: NSImage(systemSymbolName: "touchid", accessibilityDescription: "Touch ID")!)
            image.symbolConfiguration = .init(pointSize: 30, weight: .regular).applying(.init(paletteColors: [.systemPink]))
            glyph = image
        }
        glyph.translatesAutoresizingMaskIntoConstraints = false
        authSlot.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: authSlot.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: authSlot.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: Self.glyphSize),
            glyph.heightAnchor.constraint(equalToConstant: Self.glyphSize),
        ])
        retryButton.isHidden = true
        note.isHidden = true
    }

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

    func showRetry(note text: String) {
        note.stringValue = text
        note.isHidden = false
        retryButton.isHidden = false
    }

    // MARK: Sections

    private func header(_ prompt: ApprovalPrompt) -> [NSView] {
        let agent = prompt.requester.name
        let action = prompt.description.action
        let heading = NSTextField(labelWithString: prompt.description.subject != nil
            ? "\(agent) wants access to"
            : "\(agent) wants to \(action.prefix(1).lowercased() + action.dropFirst())")
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        heading.textColor = Caution.text
        waitingLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        waitingLabel.textColor = Caution.accent
        waitingLabel.isHidden = true
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy dialog text")
        copyButton.toolTip = "Copy this request as text"
        copyButton.isBordered = false
        copyButton.contentTintColor = Caution.secondary
        copyButton.target = self
        copyButton.action = #selector(copyTranscript)
        let title = NSStackView(views: [heading, NSView(), waitingLabel, copyButton])
        title.orientation = .horizontal
        title.alignment = .firstBaseline
        title.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        let whereText: String
        switch prompt.requester {
        case .agent(let a):
            whereText = a.sessionLabel.map { "in “\($0)”" } ?? "in an untitled session"
        case .terminal(let t):
            whereText = (["in a terminal tab"] + [t.info.tty, t.surfaceLabel.map { "“\($0)”" }].compactMap { $0 })
                .joined(separator: " · ")
        }
        let session = NSTextField(labelWithString: whereText)
        session.font = .systemFont(ofSize: 13)
        session.textColor = Caution.secondary
        session.lineBreakMode = .byTruncatingTail
        session.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(session)
        if prompt.requester.spacetermURL != nil {
            let link = NSButton(title: "Open in Spaceterm ↗", target: self, action: #selector(openSession))
            link.isBordered = false
            link.contentTintColor = Caution.link
            link.font = .systemFont(ofSize: 13)
            row.addArrangedSubview(link)
        }
        let kicker = NSTextField(labelWithString: "⚠︎  1PASSWORD SECURITY APPROVAL")
        kicker.font = .systemFont(ofSize: 11, weight: .heavy)
        kicker.textColor = Caution.accent
        let hero = hero(prompt)
        transcript.append(([kicker.stringValue, heading.stringValue] + [hero?.stringValue, whereText].compactMap { $0 })
            .joined(separator: "\n"))
        return [kicker, title] + (hero.map { [$0] } ?? []) + [row]
    }

    /// The item being accessed, as the headline: it's what the approval is really about.
    private func hero(_ prompt: ApprovalPrompt) -> NSTextField? {
        guard let subject = prompt.description.subject else { return nil }
        let text = NSMutableAttributedString(string: prompt.resolvedItem ?? subject, attributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .heavy), .foregroundColor: Caution.accent])
        if prompt.resolvedItem != nil {
            // The opaque ID the command actually used.
            text.append(NSAttributedString(string: "\n" + subject, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: Caution.secondary]))
        }
        let field = NSTextField(wrappingLabelWithString: "")
        field.attributedStringValue = text
        field.isSelectable = true
        field.preferredMaxLayoutWidth = Self.inner
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
        for detail in prompt.description.details {
            let value = detail.value
            let field: NSTextField
            switch detail.style {
            case .normal where detail.label == "Vault" && prompt.resolvedVault != nil:
                // The vault's name, with the ID the command used beside it.
                field = Self.value("", size: 14)
                let text = NSMutableAttributedString(string: prompt.resolvedVault!, attributes: [
                    .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: Caution.text])
                text.append(NSAttributedString(string: "  " + value, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: Caution.secondary]))
                field.attributedStringValue = text
            case .normal: field = Self.value(value, size: 14, weight: .medium)
            case .placeholder: field = Self.value(value, size: 14, color: Caution.secondary)
            }
            row(detail.label, field)
        }
        let command = "op " + prompt.request.argv.map(shellQuote).joined(separator: " ")
        row("Command", Self.value(command, size: 12, mono: true))
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
            if let via = a.caller.viaProcess { row("Called by", String(via.prefix(300))) }
        case .terminal(let t):
            row("Terminal", t.info.app + (t.info.tty.map { " · \($0)" } ?? ""))
            row("Tab session", "Unix session \(t.info.sid)")
            row("Requested by", "PID \(prompt.peerPid)")
            row("Directory", prompt.request.cwd)
        }
        Self.styleLabelColumn(grid)
        return grid
    }

    /// What Touch ID will grant; chosen before touching.
    var selectedScope: ApprovalScope { durations[max(0, durationControl.selectedSegment)].scope }

    /// "Touch ID runs this one request…": the shared hint, said of Touch ID.
    private func hintText(_ option: ApprovalOption) -> String {
        "Touch ID " + option.hint.prefix(1).lowercased() + option.hint.dropFirst()
    }

    private func footer(_ prompt: ApprovalPrompt) -> NSView {
        (durations, defaultDuration) = ApprovalOptions.for(prompt.requester)
        durationControl.segmentCount = durations.count
        for (i, d) in durations.enumerated() { durationControl.setLabel(d.label, forSegment: i) }
        durationControl.trackingMode = .selectOne
        durationControl.selectedSegment = defaultDuration
        durationControl.target = self
        durationControl.action = #selector(durationChanged)
        durationControl.controlSize = .large
        let allow = Self.label("Allow", size: 13)
        let durationRow = NSStackView(views: [allow, durationControl])
        durationRow.orientation = .horizontal
        durationRow.spacing = 10
        hint.stringValue = hintText(durations[defaultDuration])

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = Caution.secondary
        note.font = .systemFont(ofSize: 11, weight: .semibold)
        note.textColor = Caution.danger
        note.isHidden = true
        abandonedNote.font = .systemFont(ofSize: 11, weight: .semibold)
        abandonedNote.textColor = Caution.accent
        abandonedNote.isHidden = true
        let text = NSStackView(views: [durationRow, abandonedNote, hint, note])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.setCustomSpacing(8, after: durationRow)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for (button, action) in [(denyButton, #selector(deny)), (retryButton, #selector(retry))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.controlSize = .large
        }
        retryButton.isHidden = true
        authSlot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            authSlot.widthAnchor.constraint(equalToConstant: Self.glyphSize + 8),
            authSlot.heightAnchor.constraint(equalToConstant: Self.glyphSize + 8),
        ])

        let row = NSStackView(views: [text, NSView(), denyButton, retryButton, authSlot])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
        return row
    }

    @objc private func durationChanged() { hint.stringValue = hintText(durations[durationControl.selectedSegment]) }
    @objc private func retry() { actions?.retry() }
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

/// Only Touch ID and deliberate mouse input may act on an approval: keystrokes are dropped
/// (except ⌘C, to copy text), and clicks are ignored briefly after the panel appears, since a
/// click already under way can land on a button that just popped up beneath the pointer.
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
    /// out are Touch ID, Deny/Esc, or the timeout.
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

func shellQuote(_ s: String) -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=@,+%"))
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
        let shown: [String: Any] = [
            "summary": prompt.description.summary,
            "subject": prompt.description.subject ?? NSNull(),
            "resolvedItem": prompt.resolvedItem ?? NSNull(),
            "resolvedVault": prompt.resolvedVault ?? NSNull(),
            "details": prompt.description.details.map { "\($0.label)=\($0.value)" },
            "requester": prompt.requester.name,
            "label": prompt.requester.surfaceLabel ?? NSNull(),
        ]
        var fields = shown
        switch prompt.requester {
        case .agent(let a):
            fields["toolCommand"] = a.caller.toolCommand ?? NSNull()
            fields["via"] = a.caller.viaProcess ?? NSNull()
            fields["lastMessage"] = a.lastMessage.map { String($0.prefix(80)) } ?? NSNull()
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
