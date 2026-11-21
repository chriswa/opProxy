import AppKit
import OpProxyCore

/// Frames 1Password's own prompts that opProxy didn't raise. While 1Password shows a prompt and
/// a real `op` is running, a panel around the prompt says who ran it, the command, and why it
/// went to 1Password rather than opProxy: opProxy passed it through (`op run`, stdin, …), or
/// it never reached opProxy's `op` (a PATH with Homebrew first, a full path). Each one is
/// logged. Like `AuthContextPanel`, it never takes focus or clicks.
final class NativePromptWatcher {
    static let interval: TimeInterval = 0.5
    private let log: Log
    private let passthroughs: PassthroughRecord
    private let shimDir: String
    /// True while `AuthContextPanel` frames opProxy's own authorization.
    private let ownPromptShowing: () -> Bool
    private var timer: Timer?
    private var panel: NSPanel?
    private var shown: (prompt: AuthContextPanel.PromptWindow, calls: [Call])?
    private var promptSince: Date?
    /// Calls already described, by PID and start time; each is logged once.
    private var described: [String: Call] = [:]

    init(log: Log, passthroughs: PassthroughRecord, shimDir: String, ownPromptShowing: @escaping () -> Bool) {
        self.log = log
        self.passthroughs = passthroughs
        self.shimDir = shimDir
        self.ownPromptShowing = ownPromptShowing
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in self?.tick() }
    }

    struct Call: Equatable {
        let who: String
        let logName: String
        let command: String
        let subcommand: String
        let why: String
        let toolCommand: String?
        let place: String
    }

    private func tick() {
        let prompt = AuthContextPanel.promptWindow().flatMap { $0.owner == "1Password" ? $0 : nil }
        guard let prompt, !ownPromptShowing() else {
            if let since = promptSince, shown != nil {
                log.write(String(format: "1Password prompt closed after %.1fs", Date().timeIntervalSince(since)))
            }
            promptSince = nil
            hide()
            return
        }
        let calls = runningCalls()
        // Quick Access and other 1Password windows: no op is waiting, so there's nothing to say.
        guard !calls.isEmpty else { hide(); return }
        if promptSince == nil { promptSince = Date() }
        if shown?.prompt != prompt || shown?.calls != calls { show(prompt, calls) }
    }

    /// The real `op` processes running now, oldest first. The daemon's own (`account list`) are
    /// its children and never prompt; `op daemon` is the CLI's long-lived helper, not a request.
    private func runningCalls() -> [Call] {
        let me = getpid()
        let entries = ProcessTree.pids(named: "op").compactMap(ProcessTree.entry)
            .filter { $0.ppid != me && OpCommand(argv: Array($0.argv.dropFirst())).subcommand != ["daemon"] }
            .sorted { $0.startTime < $1.startTime }
        let live = Set(entries.map(Self.key))
        described = described.filter { live.contains($0.key) }
        return entries.map { entry in
            if let known = described[Self.key(entry)] { return known }
            let call = describe(entry)
            described[Self.key(entry)] = call
            log.write("1Password prompt for \(call.logName) \(call.subcommand): \(call.why) (\(call.place))")
            return call
        }
    }

    private static func key(_ e: ProcessEntry) -> String { "\(e.pid)@\(e.startTime)" }

    private func describe(_ entry: ProcessEntry) -> Call {
        let argv = Array(entry.argv.dropFirst())
        let chain = ProcessTree.ancestry(of: entry.pid)
        let who: String, logName: String
        var toolCommand: String?
        if let identity = SessionIdentity.verify(peer: entry.pid) {
            let session = AgentSession.detect(environment: entry.env, ancestry: { chain })
                .flatMap { $0.agent == identity.agent ? $0 : nil }
            let sessionId = session.map { String($0.sessionId.prefix(8)) }
            who = "\(identity.agent.displayName) Agent" + (sessionId.map { " · session \($0)" } ?? "")
            logName = "\(identity.agent.rawValue):\(sessionId ?? "pid \(identity.agentPid)")"
            toolCommand = CallerContext.from(chain: chain, agentPid: identity.agentPid).toolCommand
        } else {
            let sid = getsid(entry.pid)
            who = "A command in \(TerminalInfo.from(chain: chain, sid: sid).app)"
            logName = "terminal:\(sid)"
            toolCommand = CallerContext.from(chain: chain, agentPid: nil).toolCommand
        }
        let why: String
        if let passed = passthroughs.entry(pid: entry.pid, startTime: entry.startTime) {
            why = "opProxy passed it to 1Password: \(passed.reason)"
        } else {
            why = "It never reached opProxy: " + NativeOp.whyDirect(argv0: entry.argv.first ?? "op", path: entry.env["PATH"],
                                                                   shimDir: shimDir)
        }
        let cwd = ProcessTree.cwd(entry.pid).map(NativeOp.abbreviated) ?? "unknown directory"
        return Call(who: who, logName: logName, command: NativeOp.displayed(argv), subcommand: NativeOp.subcommand(argv),
                    why: why, toolCommand: toolCommand, place: "in \(cwd), pid \(entry.pid)")
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
        shown = nil
    }

    private func show(_ prompt: AuthContextPanel.PromptWindow, _ calls: [Call]) {
        shown = (prompt, calls)
        let panel = self.panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            // Below 1Password's prompt (window level 101), so the prompt always sits on top of it.
            p.level = .floating
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            return p
        }()
        self.panel = panel
        let frame = prompt.frame
        let view = NativePromptView(calls: calls, width: max(NativePromptView.width, frame.width + 40), gap: frame.height)
        panel.contentView = view
        let size = view.fittingSize
        panel.setFrame(NSRect(origin: NSPoint(x: frame.midX - size.width / 2, y: frame.minY - view.heightBelowGap), size: size),
                       display: true)
        panel.orderFrontRegardless()
    }
}

/// The backdrop: who and what above the prompt, a gap it fills, the details below.
final class NativePromptView: NSView {
    static let width: CGFloat = 480
    private let theme = SetupTheme.violet
    private(set) var heightBelowGap: CGFloat = 0

    init(calls: [NativePromptWatcher.Call], width: CGFloat = NativePromptView.width, gap: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        let stripe = HazardStripe()
        stripe.light = theme.stripeLight
        stripe.dark = theme.stripeDark
        stripe.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stripe)

        func text(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor? = nil, mono: Bool = false) -> NSTextField {
            let f = NSTextField(wrappingLabelWithString: s)
            f.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
            f.textColor = color ?? theme.text
            f.preferredMaxLayoutWidth = width - 40
            return f
        }
        let first = calls[0]
        let kicker = text("opProxy · 1Password is asking, not opProxy", size: 12, weight: .heavy, color: theme.accent)
        let title = text("\(first.who) ran \(first.subcommand)", size: 15, weight: .bold)
        let above = NSStackView(views: [kicker, title])
        above.orientation = .vertical
        above.alignment = .leading
        above.spacing = 3
        above.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)

        let below = NSStackView()
        below.orientation = .vertical
        below.alignment = .leading
        below.spacing = 6
        below.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 16, right: 20)
        below.addArrangedSubview(text(String(first.command.prefix(300)), size: 12, weight: .semibold, mono: true))
        below.addArrangedSubview(text(first.why + ".", size: 12, weight: .semibold))
        if let tool = first.toolCommand {
            below.addArrangedSubview(text("Its shell command:", size: 11, color: theme.secondary))
            below.addArrangedSubview(text(Self.clipped(tool), size: 11, color: theme.secondary, mono: true))
        }
        below.addArrangedSubview(text(first.place.prefix(1).uppercased() + first.place.dropFirst(), size: 11, color: theme.secondary))
        if calls.count > 1 {
            let others = calls.dropFirst().prefix(3).map { "\($0.who): \($0.subcommand)" }.joined(separator: "\n")
            below.addArrangedSubview(text("Also waiting on 1Password:\n" + others, size: 11, color: theme.secondary))
        }
        below.addArrangedSubview(text("1Password's prompt names the app that owns the terminal session, which may not be "
                                      + "the agent. ~/.opProxy/daemon.log records these.", size: 11, color: theme.secondary))

        let spacer = NSView()
        let column = NSStackView(views: [above, spacer, below])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            stripe.leadingAnchor.constraint(equalTo: leadingAnchor),
            stripe.trailingAnchor.constraint(equalTo: trailingAnchor),
            stripe.topAnchor.constraint(equalTo: topAnchor),
            stripe.heightAnchor.constraint(equalToConstant: 10),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: stripe.bottomAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.widthAnchor.constraint(equalToConstant: width),
            spacer.heightAnchor.constraint(equalToConstant: gap),
            spacer.widthAnchor.constraint(equalToConstant: width),
        ])
        layoutSubtreeIfNeeded()
        heightBelowGap = below.fittingSize.height
    }

    /// At most six lines and 500 characters of an agent's shell command.
    static func clipped(_ s: String) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        var out = lines.prefix(6).joined(separator: "\n")
        if out.count > 500 { out = String(out.prefix(500)) }
        return out.count < s.count ? out + " …" : out
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = theme.background.cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = theme.border.cgColor
        layer?.masksToBounds = true
    }
}
