import Darwin
import Foundation
import LocalAuthentication
import OpProxyCore

/// How long an approval lasts, as chosen in the dialog.
enum ApprovalScope: Equatable {
    /// Run this request only; remember nothing.
    case once
    /// Agents: this exact command in this agent session, for this long.
    case lasting(TimeInterval)
    /// Terminals: every read from the tab, 1Password-style (idle timeout, 12-hour cap).
    case tab
}

enum Decision {
    /// Carries the Touch ID-evaluated context that authorizes signing the approval.
    case approved(LAContext?, ApprovalScope)
    case denied, timedOut

    var label: String {
        switch self {
        case .approved: return "approved"
        case .denied: return "denied"
        case .timedOut: return "timedOut"
        }
    }

    init?(scripted: String) {
        switch scripted {
        case "approved": self = .approved(nil, .lasting(ApprovalStore.defaultTTL))
        case "approved-once": self = .approved(nil, .once)
        case "approved-hour": self = .approved(nil, .lasting(3600))
        case "denied": self = .denied
        case "timedOut": self = .timedOut
        default: return nil
        }
    }
}

/// Identifies one dialog: identical requests share it.
enum DialogKey: Hashable {
    case agent(ApprovalKey)
    case terminal(TerminalKey)
}

/// Who is asking, with everything the dialog can show about them.
enum Requester {
    case agent(AgentRequester)
    case terminal(TerminalRequester)

    var name: String {
        switch self {
        case .agent(let a): return a.session.agent.displayName
        case .terminal(let t): return t.info.app == "unknown process" ? "A process" : t.info.app
        }
    }

    /// Spaceterm surface title and link, when the caller is in one.
    var surfaceLabel: String? {
        switch self {
        case .agent(let a): return a.sessionLabel
        case .terminal(let t): return t.surfaceLabel
        }
    }

    var spacetermURL: URL? {
        switch self {
        case .agent(let a): return a.session.spacetermURL
        case .terminal(let t): return t.surfaceId.flatMap { URL(string: "spaceterm-surface://\($0)") }
        }
    }
}

struct AgentRequester {
    /// As the caller claims it; only the agent process behind it is verified.
    let session: AgentSession
    let sessionLabel: String?
    let caller: CallerContext
    let lastMessage: String?
    let agentPid: pid_t
}

struct TerminalRequester {
    let info: TerminalInfo
    let surfaceId: String?
    let surfaceLabel: String?
}

/// Everything the approval dialog shows.
struct ApprovalPrompt {
    let key: DialogKey
    let request: ProxyRequest
    let requester: Requester
    let description: OpCommand.Description
    /// Names looked up when the request uses opaque IDs.
    let resolvedItem: String?
    let resolvedVault: String?
    /// The process that asked (usually the shim).
    let peerPid: pid_t
}

protocol Approver: AnyObject {
    /// Called on the daemon's state queue; `completion` may be called on any queue.
    func requestApproval(_ prompt: ApprovalPrompt, completion: @escaping (Decision) -> Void)
    /// Everyone waiting on `key`'s dialog has disconnected.
    func requestersLeft(_ key: DialogKey)
}

struct NoApprovalKey: Error {}

/// Serves shim requests from one long-lived process, running `op` through `AuthTracker`'s
/// session holder so 1Password authorizes once rather than per call.
final class Daemon {
    let paths: Paths
    let approver: Approver
    let log: Log
    private let store: ApprovalStore
    private let terminals: TerminalApprovals
    private let stateQueue = DispatchQueue(label: "opProxy.state")
    private var pending: [DialogKey: [(Decision) -> Void]] = [:]
    /// How many of `pending[key]`'s requesters have closed their connection.
    private var departed: [DialogKey: Int] = [:]
    let auth: AuthTracker
    private let signer: ApprovalSigner?
    /// The Touch ID-evaluated context from the latest approval. Only this process holds it;
    /// it lets the menu re-sign an approval's expiry without another touch.
    private var signingContext: LAContext?

    init(paths: Paths, approver: Approver, log: Log, auth: AuthTracker) {
        self.paths = paths
        self.approver = approver
        self.log = log
        self.auth = auth
        signer = makeApprovalSigner(paths: paths)
        store = makeApprovalStore(paths: paths, signer: signer)
        terminals = TerminalApprovals(idle: Double(TestKnobs.value("OPPROXY_TERMINAL_IDLE") ?? "") ?? TerminalApprovals.defaultIdle)
    }

    func start() throws {
        try paths.ensureStateDir()
        let listener = try UnixSocket.listen(path: paths.socket.path)
        log.write("listening on \(paths.socket.path); real op at \(paths.realOp)")
        if signer == nil { log.write("warning: no pinned approval key; approvals won't be remembered (run install.sh)") }
        let rejected = stateQueue.sync { store.rejected.count }
        if rejected > 0 { log.write("warning: ignoring \(rejected) approval(s) with invalid signatures") }
        Thread.detachNewThread { [self] in
            while true {
                let fd = accept(listener, nil, nil)
                if fd < 0 { continue }
                UnixSocket.noSigpipe(fd)
                DispatchQueue.global().async { self.serve(fd) }
            }
        }
        auth.startPolling()
    }

    // MARK: Recent approvals, for the menu

    struct RecentApproval {
        enum Target {
            case agent(ApprovalKey)
            case terminal(TerminalKey)
        }
        let target: Target
        /// Item name, or the terminal tab for tab-wide approvals.
        let title: String
        /// Who: "Claude Code “title”", "iTerm · ttys012".
        let requester: String
        let command: String?
        let approvedAt: Date
        /// nil for terminal tabs, which lapse after idling.
        let expiresAt: Date?
    }

    /// Unexpired approvals, newest first.
    func recentApprovals(limit: Int) -> [RecentApproval] {
        stateQueue.sync {
            let agents = store.active.map { a in
                RecentApproval(target: .agent(a.key),
                               title: a.itemLabel ?? OpCommand(argv: a.key.argv).description.subject ?? "op " + (a.key.argv.first ?? ""),
                               requester: a.key.agent.displayName + (a.sessionLabel.map { " “\($0)”" } ?? ""),
                               command: "op " + a.key.argv.joined(separator: " "), approvedAt: a.approvedAt, expiresAt: a.expiresAt)
            }
            let tabs = terminals.active.map { t in
                RecentApproval(target: .terminal(t.key), title: "All reads from this terminal tab", requester: t.label,
                               command: nil, approvedAt: t.approvedAt, expiresAt: nil)
            }
            return Array((agents + tabs).sorted { $0.approvedAt > $1.approvedAt }.prefix(limit))
        }
    }

    enum Revocation {
        case one(RecentApproval.Target)
        /// Every approval for that agent session ID (or that terminal tab).
        case session(RecentApproval.Target)
        case all
    }

    func revoke(_ revocation: Revocation) {
        stateQueue.sync {
            do {
                switch revocation {
                case .one(.agent(let k)):
                    try store.revoke { $0.key == k }
                case .session(.agent(let k)):
                    try store.revoke { $0.key.agent == k.agent && $0.key.sessionId == k.sessionId }
                case .one(.terminal(let k)), .session(.terminal(let k)):
                    terminals.revoke(k)
                case .all:
                    try store.revoke { _ in true }
                    terminals.revokeAll()
                }
            } catch {
                log.write("could not revoke: \(error)")
            }
        }
    }

    enum ExpiryChange: Equatable {
        case changed
        /// No authenticated signing context yet (e.g. right after a restart): Touch ID first.
        case needsTouchID
        case failed(String)
    }

    /// Re-signs an agent approval to expire at `expiresAt`, with `context` if given (it just
    /// passed Touch ID) or else the context kept from the latest approval.
    func changeExpiry(_ key: ApprovalKey, to expiresAt: Date, context: LAContext? = nil) -> ExpiryChange {
        stateQueue.sync {
            guard let signer else { return .failed("this build has no approval key") }
            if let context { signingContext = context }
            guard let signingContext else { return .needsTouchID }
            // Never let a stale context raise UI from inside the daemon; ask for Touch ID instead.
            signingContext.interactionNotAllowed = true
            do {
                guard try store.changeExpiry(key, to: expiresAt, sign: { try signer.sign($0, context: signingContext) }) else {
                    return .failed("that approval has already expired or been revoked")
                }
                log.write("changed expiry: \(key.agent.rawValue):\(key.sessionId.prefix(8)) op \(key.argv.joined(separator: " "))")
                return .changed
            } catch {
                self.signingContext = nil
                return context == nil ? .needsTouchID : .failed("\(error)")
            }
        }
    }

    func status(error: String? = nil) -> DaemonStatus {
        DaemonStatus(auth: auth.current, activeApprovals: stateQueue.sync { store.active.count }, error: error)
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        let peer = UnixSocket.peerPid(fd)
        guard let line = LineReader(fd: fd, limit: 1 << 20).next(),
              let message = try? JSONDecoder().decode(DaemonMessage.self, from: line) else { return }
        let reply: Data?
        switch message {
        case .proxy(let request): reply = try? JSONEncoder().encode(handle(request, peer: peer, fd: fd))
        case .status: reply = try? JSONEncoder().encode(status())
        case .refresh: reply = try? JSONEncoder().encode(status(error: auth.refresh()))
        }
        if let reply { _ = UnixSocket.writeAll(fd, reply) }
    }

    private func handle(_ request: ProxyRequest, peer: pid_t?, fd: Int32) -> ProxyResponse {
        let command = "op " + request.argv.joined(separator: " ")
        // Anything can write to the socket, so routing comes from argv here, not the client.
        guard case .proxy(let plan) = OpCommand(argv: request.argv).routing, let peer else {
            log.write("rejected: \(command)")
            return .failure("opProxy only proxies read-only commands; `\(command)` must run directly.")
        }
        // Env vars are forgeable; the process tree decides whether an agent is asking. A
        // genuine agent anywhere above the caller means agent rules, whatever the env says.
        let key: DialogKey
        let tag: String
        if let identity = SessionIdentity.verify(peer: peer) {
            let claimed = request.session.flatMap { $0.agent == identity.agent ? $0 : nil }
            let session = claimed ?? AgentSession(agent: identity.agent, sessionId: "unknown", surfaceId: request.surfaceId)
            tag = "\(session.agent.rawValue):\(session.sessionId.prefix(8)) \(command)"
            let approvalKey = ApprovalKey(agent: session.agent, sessionId: session.sessionId,
                                          agentInstance: identity.agentInstance, argv: request.argv, env: request.env)
            key = .agent(approvalKey)
            if !plan.requiresApproval || stateQueue.sync(execute: { store.isApproved(approvalKey) }) {
                log.write("allowed: \(tag)")
                return auth.run(plan.daemonArgv, extraEnv: request.env)
            }
            let prompt = { self.agentPrompt(request, session: session, key: key, peer: peer, identity: identity) }
            if let refusal = decide(prompt, key: key, tag: tag, fd: fd) { return refusal }
        } else {
            guard let terminal = TerminalKey.of(pid: peer) else { return .usePassthrough }
            tag = "terminal:\(terminal.sid) \(command)"
            key = .terminal(terminal)
            if !plan.requiresApproval || stateQueue.sync(execute: { terminals.use(terminal) }) {
                log.write("allowed: \(tag)")
                return auth.run(plan.daemonArgv, extraEnv: request.env)
            }
            let prompt = { self.terminalPrompt(request, key: key, peer: peer, sid: terminal.sid) }
            if let refusal = decide(prompt, key: key, tag: tag, fd: fd) { return refusal }
        }
        return auth.run(plan.daemonArgv, extraEnv: request.env)
    }

    /// Shows (or joins) the dialog for `key`; nil means approved.
    private func decide(_ makePrompt: () -> ApprovalPrompt, key: DialogKey, tag: String, fd: Int32) -> ProxyResponse? {
        let decision = awaitDecision(makePrompt(), fd: fd)
        log.write("\(decision.label): \(tag)")
        switch decision {
        case .approved: return nil
        case .denied:
            return .failure("the user denied this 1Password request. Ask them before retrying `op \(tag.split(separator: " ", maxSplits: 2).last ?? "")`.")
        case .timedOut:
            return .failure("the approval dialog timed out without an answer. Ask the user before retrying.")
        }
    }

    private func isApproved(_ key: DialogKey) -> Bool {
        switch key {
        case .agent(let k): return store.isApproved(k)
        case .terminal(let k): return terminals.use(k)
        }
    }

    /// Agent approvals are signed and persisted; terminal ones live in memory. "Only this
    /// once" records nothing: the waiting request just runs.
    private func record(_ decision: Decision, for prompt: ApprovalPrompt) {
        guard case .approved(let context, let scope) = decision else { return }
        switch (prompt.key, scope) {
        case (_, .once):
            break
        case (.terminal(let k), _):
            if case .terminal(let t) = prompt.requester {
                terminals.approve(k, label: t.info.app + (t.info.tty.map { " · \($0)" } ?? ""))
            }
        case (.agent(let k), .lasting(let ttl)):
            if let context { signingContext = context }
            do {
                try store.approve(k, sessionLabel: prompt.requester.surfaceLabel,
                                  itemLabel: prompt.resolvedItem ?? prompt.description.subject, ttl: ttl) { payload in
                    guard let signer else { throw NoApprovalKey() }
                    return try signer.sign(payload, context: context)
                }
            } catch {
                log.write("approved once, not remembered: could not sign the approval: \(error)")
            }
        case (.agent, .tab):
            break
        }
    }

    private func awaitDecision(_ prompt: ApprovalPrompt, fd: Int32) -> Decision {
        let key = prompt.key
        let done = DispatchSemaphore(value: 0)
        var result = Decision.denied
        stateQueue.sync {
            // Approved while this request was gathering context.
            if isApproved(key) { result = .approved(nil, .once); done.signal(); return }
            let waiter: (Decision) -> Void = { result = $0; done.signal() }
            if pending[key] != nil {
                pending[key]!.append(waiter)
                return
            }
            pending[key] = [waiter]
            log.write("prompting: \(Self.describe(key)) op \(prompt.request.argv.joined(separator: " "))")
            approver.requestApproval(prompt) { [self] decision in
                stateQueue.async { [self] in
                    record(decision, for: prompt)
                    pending.removeValue(forKey: key)?.forEach { $0(decision) }
                    departed.removeValue(forKey: key)
                }
            }
        }
        let stopWatching = watchForDeparture(fd, key: key)
        done.wait()
        stopWatching()
        return result
    }

    private static func describe(_ key: DialogKey) -> String {
        switch key {
        case .agent(let k): return "\(k.agent.rawValue):\(k.sessionId)"
        case .terminal(let k): return "terminal:\(k.sid)"
        }
    }

    /// Agents often give up on a slow command before the user answers. When every requester
    /// for a dialog has gone, the dialog says so; approving still helps, since the retry then
    /// runs silently. Returns a function that stops watching.
    private func watchForDeparture(_ fd: Int32, key: DialogKey) -> () -> Void {
        let lock = NSLock()
        var stop = false
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { [self] in
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            while !lock.withLock({ stop }) {
                guard poll(&p, 1, 250) > 0 else { continue }
                if UnixSocket.peerClosed(fd) {
                    requesterLeft(key)
                    break
                }
                usleep(250_000)  // unexpected extra bytes; don't spin
            }
            finished.signal()
        }
        return {
            lock.withLock { stop = true }
            finished.wait()  // `fd` is closed after this; the watcher must be done with it
        }
    }

    private func requesterLeft(_ key: DialogKey) {
        stateQueue.async { [self] in
            guard let waiting = pending[key]?.count else { return }
            departed[key, default: 0] += 1
            if departed[key] == waiting {
                log.write("requester stopped waiting: \(Self.describe(key))")
                approver.requestersLeft(key)
            }
        }
    }

    private func agentPrompt(_ request: ProxyRequest, session: AgentSession, key: DialogKey, peer: pid_t,
                             identity: SessionIdentity) -> ApprovalPrompt {
        let command = OpCommand(argv: request.argv)
        let caller = CallerContext.from(chain: ProcessTree.ancestry(of: peer), agentPid: identity.agentPid)
        let requester = AgentRequester(session: session, sessionLabel: spacetermLabel(session.surfaceId ?? request.surfaceId),
                                       caller: caller, lastMessage: SessionInfo.lastAgentMessage(session),
                                       agentPid: identity.agentPid)
        let names = resolveNames(command, env: request.env, mayPrompt: true)
        return ApprovalPrompt(key: key, request: request, requester: .agent(requester), description: command.description,
                              resolvedItem: names?.item, resolvedVault: names?.vault, peerPid: peer)
    }

    private func terminalPrompt(_ request: ProxyRequest, key: DialogKey, peer: pid_t, sid: pid_t) -> ApprovalPrompt {
        let command = OpCommand(argv: request.argv)
        let info = TerminalInfo.from(chain: ProcessTree.ancestry(of: peer), sid: sid)
        let requester = TerminalRequester(info: info, surfaceId: request.surfaceId, surfaceLabel: spacetermLabel(request.surfaceId))
        let names = resolveNames(command, env: request.env, mayPrompt: true)
        return ApprovalPrompt(key: key, request: request, requester: .terminal(requester), description: command.description,
                              resolvedItem: names?.item, resolvedVault: names?.vault, peerPid: peer)
    }

    private func spacetermLabel(_ surfaceId: String?) -> String? {
        surfaceId.flatMap { SessionInfo.spacetermLabel(surfaceId: $0, environment: ProcessInfo.processInfo.environment) }
    }

    struct ResolvedNames {
        /// Set when the request named the item by ID.
        let item: String?
        /// Set when the request named the vault by ID.
        let vault: String?
    }

    private let namesLock = NSLock()
    private var nameCache: [String: (title: String, vault: String?)] = [:]

    /// Looks up names for opaque item and vault IDs by asking the real `op`, so the dialog and
    /// menu never show a bare ID. With `mayPrompt`, an unauthorized daemon asks 1Password
    /// first; the request needs that authorization anyway, so it only moves the prompt earlier.
    private func resolveNames(_ command: OpCommand, env: [String: String], mayPrompt: Bool) -> ResolvedNames? {
        var item: String?
        var vault: String?
        switch command.subcommand.joined(separator: " ") {
        case "read":
            let ref = command.positionals.first.flatMap(SecretReference.init)
            (item, vault) = (ref?.item, ref?.vault)
        case "item get", "document get":
            (item, vault) = (command.positionals.first, command.flags["--vault"])
        default:
            return nil
        }
        guard let item, OpCommand.looksLikeID(item) || vault.map(OpCommand.looksLikeID) == true else { return nil }
        let account = command.flags["--account"].map { ["--account", $0] } ?? []
        let cacheKey = ([item, vault ?? ""] + account).joined(separator: "\u{1f}")
        if let hit = namesLock.withLock({ nameCache[cacheKey] }) {
            return names(hit, item: item, vault: vault)
        }
        if !mayPrompt, auth.run(["whoami"] + account, extraEnv: env, timeout: 5).exitCode != 0 { return nil }
        let lookup = auth.run(["item", "get", item, "--format", "json"] + (vault.map { ["--vault", $0] } ?? []) + account,
                              extraEnv: env, timeout: 90)
        guard lookup.exitCode == 0,
              let obj = try? JSONSerialization.jsonObject(with: lookup.stdout) as? [String: Any],
              let title = obj["title"] as? String else { return nil }
        let found = (title: title, vault: (obj["vault"] as? [String: Any])?["name"] as? String)
        namesLock.withLock { nameCache[cacheKey] = found }
        return names(found, item: item, vault: vault)
    }

    private func names(_ found: (title: String, vault: String?), item: String, vault: String?) -> ResolvedNames {
        ResolvedNames(item: OpCommand.looksLikeID(item) ? found.title : nil,
                      vault: vault.map(OpCommand.looksLikeID) == true ? found.vault : nil)
    }

    /// Replaces approval labels that are bare IDs (approved before a name could be looked up)
    /// with the item's name. Never prompts; runs only while the daemon is authorized.
    func repairItemLabels() {
        let bare = stateQueue.sync { store.active.filter { $0.itemLabel.map(OpCommand.looksLikeID) ?? true } }
        for approval in bare {
            guard let names = resolveNames(OpCommand(argv: approval.key.argv), env: approval.key.env, mayPrompt: false),
                  let title = names.item else { continue }
            stateQueue.sync { try? store.setItemLabel(approval.key, to: title) }
        }
    }
}

final class Log {
    private let handle: FileHandle?
    private let queue = DispatchQueue(label: "opProxy.log")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    init(url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func write(_ message: String) {
        queue.sync { [self] in
            let line = "\(formatter.string(from: Date())) \(message)\n"
            handle?.write(Data(line.utf8))
        }
    }
}
