import Darwin
import Foundation
import LocalAuthentication
import OpProxyCore

/// Which agents a lasting approval covers, as chosen in the dialog.
enum ApprovalReach: CaseIterable {
    /// The asking agent's session (or its process, when it names no session).
    case thisAgent
    case allAgents

    var label: String {
        switch self {
        case .thisAgent: return "This agent"
        case .allAgents: return "All agents"
        }
    }
}

/// What an approval grants, as chosen in the dialog.
enum ApprovalScope: Equatable {
    /// Run this request only; remember nothing.
    case once
    /// Agents: every read of this item, for `ApprovalReach`, for `ApprovalLifetime`.
    case lasting(ApprovalLifetime, ApprovalReach)
    /// Terminals: every read from the tab, 1Password-style (idle timeout, 12-hour cap).
    case tab

    /// The key a lasting agent approval is stored under, given the requester's own key.
    func storedKey(for request: ApprovalKey) -> ApprovalKey? {
        guard case .lasting(_, let reach) = self else { return nil }
        return reach == .allAgents ? request.reaching(.allAgents) : request
    }
}

/// One choice of what an approval grants. The dialog and the approval feed both offer
/// exactly these; `id` is what a phone's statement picks.
struct ApprovalOption {
    let id: String
    let label: String
    let scope: ApprovalScope
    /// Explains the choice; the dialog prefixes "Touch ID".
    let hint: String
}

enum ApprovalOptions {
    static func `for`(_ requester: Requester) -> (options: [ApprovalOption], defaultIndex: Int) {
        let once = ApprovalOption(id: "once", label: "Once", scope: .once, hint: "Runs this one request and remembers nothing.")
        switch requester {
        case .agent(let a):
            let lasting = ApprovalLifetime.allCases.flatMap { lifetime in
                ApprovalReach.allCases.map { reach in
                    ApprovalOption(id: id(lifetime, reach), label: "\(lifetime.label) · \(reach.label)",
                                   scope: .lasting(lifetime, reach), hint: hint(lifetime, reach, agent: a.session.agent))
                }
            }
            return ([once] + lasting, 0)
        case .terminal:
            return ([
                once,
                ApprovalOption(id: "tab", label: "This Terminal Tab", scope: .tab,
                               hint: "Approves reads from this terminal tab until it's unused for 10 minutes (12 hours at most)."),
            ], 1)
        }
    }

    /// "1d", "forever-all": what a phone's statement picks.
    private static func id(_ lifetime: ApprovalLifetime, _ reach: ApprovalReach) -> String {
        (lifetime == .day ? "1d" : "forever") + (reach == .allAgents ? "-all" : "")
    }

    private static func hint(_ lifetime: ApprovalLifetime, _ reach: ApprovalReach, agent: AgentKind) -> String {
        switch (lifetime, reach) {
        case (.day, .thisAgent):
            return "Approves every field of this item for this \(agent.displayName) session for 1 day, including if the session is resumed."
        case (.day, .allAgents):
            return "Approves every field of this item for every Claude Code, Codex and Cursor session for 1 day."
        case (.forever, .thisAgent):
            return "Approves every field of this item for this \(agent.displayName) session until you revoke it, including if the session is resumed."
        case (.forever, .allAgents):
            return "Approves every field of this item for every agent session until you revoke it."
        }
    }
}

/// Who approved, and what that lets the daemon store.
enum Authority {
    /// The dialog's Touch ID-evaluated context, which authorizes signing the approval.
    case touchID(LAContext?)
    /// A paired phone. A lasting approval is stored with the phone's proof and exactly the
    /// times its challenge committed to; `grant` is nil for options that store nothing.
    case device(DeviceProof, grant: (approvedAt: Date, expiresAt: Date)?)
}

enum Decision {
    case approved(Authority, ApprovalScope)
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
        case "approved": self = .approved(.touchID(nil), .lasting(.day, .thisAgent))
        case "approved-once": self = .approved(.touchID(nil), .once)
        case "approved-all": self = .approved(.touchID(nil), .lasting(.forever, .allAgents))
        case "denied": self = .denied
        case "timedOut": self = .timedOut
        default: return nil
        }
    }
}

/// Identifies one dialog: requests for the same item from the same requester share it.
enum DialogKey: Hashable {
    case agent(ApprovalKey)
    case terminal(TerminalKey)
}

/// Who is asking, with everything the dialog can show about them.
enum Requester {
    case agent(AgentRequester)
    case terminal(TerminalRequester)

    /// "Claude Code", or the terminal app.
    var kind: String {
        switch self {
        case .agent(let a): return a.session.agent.displayName
        case .terminal(let t): return t.info.app == "unknown process" ? "A process" : t.info.app
        }
    }

    /// "Kevin (Claude Code)" when the label command named the agent, else "Claude Code".
    var name: String {
        label?.name.map { "\($0) (\(kind))" } ?? kind
    }

    /// The dialog's first headline: "Kevin" when the label command named the agent, else
    /// "Claude Code Agent"; for a terminal, its app.
    var headline: String {
        switch self {
        case .agent: return label?.name ?? "\(kind) Agent"
        case .terminal: return label?.name ?? kind
        }
    }

    /// What the configured label command says about the caller, if anything.
    var label: RequesterLabel? {
        switch self {
        case .agent(let a): return a.label
        case .terminal(let t): return t.label
        }
    }

    /// The label's title: the only part of the label an approval stores.
    var labelTitle: String? { label?.title }
}

struct AgentRequester {
    /// As the caller claims it; only the agent process behind it is verified.
    let session: AgentSession
    let label: RequesterLabel?
    let caller: CallerContext
    let lastMessage: String?
    let agentPid: pid_t
}

struct TerminalRequester {
    let info: TerminalInfo
    let label: RequesterLabel?
}

/// Everything the approval dialog shows.
struct ApprovalPrompt {
    let key: DialogKey
    let request: ProxyRequest
    let requester: Requester
    let item: ItemRequest
    /// The item `item` was resolved to: what approving grants.
    let target: ItemIdentity
    /// The process that asked (usually the shim).
    let peerPid: pid_t

    /// Completes the system's "opProxy is trying to …" sentence; capitalized, it's also the
    /// line a phone shows beside its slide control.
    var touchIDReason: String {
        let who = requester.labelTitle.map { "\(requester.name) in “\($0)”" } ?? requester.name
        return "let \(who) \(item.summary(target))"
    }
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
    let devices: PairedDeviceStore
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

    init(paths: Paths, approver: Approver, log: Log, auth: AuthTracker, signer: ApprovalSigner?, devices: PairedDeviceStore) {
        self.paths = paths
        self.approver = approver
        self.log = log
        self.auth = auth
        self.signer = signer
        self.devices = devices
        store = makeApprovalStore(paths: paths, signer: signer, devices: devices)
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
        /// "Vault / Item", or the terminal tab for tab-wide approvals.
        let title: String
        /// Who: "Claude Code “title”", "iTerm · ttys012".
        let requester: String
        /// The item's IDs, for agent approvals.
        let ids: String?
        let approvedAt: Date
        /// nil for terminal tabs, which lapse after idling.
        let expiresAt: Date?
        /// For an all-agents approval: the requester it can be narrowed back to.
        let grantedTo: ApprovalAudience?
    }

    /// "Claude Code “title”", "All agents".
    private static func describe(_ a: Approval) -> String {
        switch a.key.audience {
        case .session(let agent, _), .process(let agent, _):
            return agent.displayName + (a.sessionLabel.map { " “\($0)”" } ?? "")
        case .allAgents:
            return "All agents"
        }
    }

    /// Unexpired approvals, newest first.
    func recentApprovals(limit: Int) -> [RecentApproval] {
        stateQueue.sync {
            let agents = store.active.map { a in
                RecentApproval(target: .agent(a.key), title: a.label, requester: Self.describe(a),
                               ids: "item \(a.key.item.itemId) · vault \(a.key.item.vaultId)",
                               approvedAt: a.approvedAt, expiresAt: a.expiresAt, grantedTo: a.grantedTo)
            }
            let tabs = terminals.active.map { t in
                RecentApproval(target: .terminal(t.key), title: "All reads from this terminal tab", requester: t.label,
                               ids: nil, approvedAt: t.approvedAt, expiresAt: nil, grantedTo: nil)
            }
            return Array((agents + tabs).sorted { $0.approvedAt > $1.approvedAt }.prefix(limit))
        }
    }

    enum Revocation {
        case one(RecentApproval.Target)
        /// Every approval for that agent session (or that terminal tab).
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
                    try store.revoke { $0.key.audience == k.audience }
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

    enum Amendment: Equatable {
        case changed
        /// No authenticated signing context yet (e.g. right after a restart): Touch ID first.
        case needsTouchID
        case failed(String)
    }

    /// Re-signs an agent approval for a new audience and/or expiry, with `context` if given (it
    /// just passed Touch ID) or else the context kept from the latest approval.
    func amend(_ key: ApprovalKey, audience: ApprovalAudience? = nil, expiresAt: Date? = nil,
               context: LAContext? = nil) -> Amendment {
        stateQueue.sync {
            guard let signer else { return .failed("this build has no approval key") }
            if let context { signingContext = context }
            guard let signingContext else { return .needsTouchID }
            // Never let a stale context raise UI from inside the daemon; ask for Touch ID instead.
            signingContext.interactionNotAllowed = true
            do {
                guard try store.amend(key, audience: audience, expiresAt: expiresAt,
                                      sign: { try signer.sign($0, context: signingContext) }) else {
                    return .failed("that approval has already expired or been revoked")
                }
                log.write("amended: \(key.audience.logName) → \((audience ?? key.audience).logName)"
                          + "\(expiresAt.map { " until \($0)" } ?? "") item \(key.item.itemId)")
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

    /// Who is asking, as far as the process tree shows.
    private enum Caller {
        case agent(SessionIdentity, AgentSession, ApprovalAudience)
        case terminal(TerminalKey)

        var logName: String {
            switch self {
            case .agent(_, let session, _): return "\(session.agent.rawValue):\(session.sessionId.prefix(8))"
            case .terminal(let t): return "terminal:\(t.sid)"
            }
        }
    }

    /// Env vars are forgeable; the process tree decides whether an agent is asking. A genuine
    /// agent anywhere above the caller means agent rules, whatever the env says.
    private func identify(_ request: ProxyRequest, peer: pid_t) -> Caller? {
        if let identity = SessionIdentity.verify(peer: peer) {
            let claimed = request.session.flatMap { $0.agent == identity.agent ? $0 : nil }
            let session = claimed ?? AgentSession(agent: identity.agent, sessionId: "unknown")
            // An agent that names no session gets its process as the audience, so nameless
            // agents never share approvals with each other.
            let audience: ApprovalAudience = claimed.map { .session(agent: $0.agent, sessionId: $0.sessionId) }
                ?? .process(agent: identity.agent, instance: identity.agentInstance)
            return .agent(identity, session, audience)
        }
        let lookalikes = ProcessTree.ancestry(of: peer).dropFirst().filter { AgentKind.matching($0) != nil }
        if !lookalikes.isEmpty {
            log.write("unverified agent process \(lookalikes.map { "\($0.name) \($0.pid)" }.joined(separator: ", ")); "
                      + "treating the caller as a terminal")
        }
        return TerminalKey.of(pid: peer).map(Caller.terminal)
    }

    private func handle(_ request: ProxyRequest, peer: pid_t?, fd: Int32) -> ProxyResponse {
        let command = "op " + request.argv.joined(separator: " ")
        // Anything can write to the socket, so routing comes from argv here, not the client.
        guard case .proxy(let plan) = OpCommand(argv: request.argv).routing, let peer else {
            log.write("rejected: \(command)")
            return .failure("opProxy only proxies read-only commands; `\(command)` must run directly.")
        }
        guard let caller = identify(request, peer: peer) else { return .usePassthrough }
        var tag = "\(caller.logName) \(command)"
        guard let item = plan.item else {
            log.write("allowed: \(tag)")
            return auth.run(plan.daemonArgv, extraEnv: request.env)
        }
        // Work out which item this is before anything else, so the approval check, the dialog
        // and the command that runs all refer to the same item, by ID.
        let target: ItemIdentity
        switch resolve(item, env: request.env) {
        case .success(let found): target = found
        case .failure(let refusal):
            log.write("unresolved: \(tag)")
            return refusal.response
        }
        tag += " → \(target.label)"
        let argv = item.pinned(to: target)
        let key: DialogKey
        switch caller {
        case .agent(_, _, let audience):
            let account = item.account ?? request.env["OP_ACCOUNT"].flatMap { $0.isEmpty ? nil : $0 }
            key = .agent(ApprovalKey(audience: audience,
                                     item: ItemRef(account: account, vaultId: target.vaultId, itemId: target.itemId)))
        case .terminal(let terminal):
            key = .terminal(terminal)
        }
        if stateQueue.sync(execute: { isApproved(key) }) {
            log.write("allowed: \(tag)")
            return auth.run(argv, extraEnv: request.env)
        }
        let prompt: () -> ApprovalPrompt
        switch caller {
        case .agent(let identity, let session, _):
            prompt = { self.agentPrompt(request, item: item, target: target, session: session, key: key, peer: peer,
                                        identity: identity) }
        case .terminal(let terminal):
            prompt = { self.terminalPrompt(request, item: item, target: target, key: key, peer: peer, sid: terminal.sid) }
        }
        if let refusal = decide(prompt, key: key, tag: tag, fd: fd) { return refusal }
        return auth.run(argv, extraEnv: request.env)
    }

    /// Shows (or joins) the dialog for `key`; nil means approved.
    private func decide(_ makePrompt: () -> ApprovalPrompt, key: DialogKey, tag: String, fd: Int32) -> ProxyResponse? {
        let decision = awaitDecision(makePrompt(), fd: fd)
        log.write("\(decision.label): \(tag)")
        switch decision {
        case .approved: return nil
        case .denied:
            return .failure("the user denied this 1Password request. Ask them before retrying.")
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
        guard case .approved(let authority, let scope) = decision else { return }
        switch (prompt.key, scope) {
        case (_, .once):
            break
        case (.terminal(let k), _):
            if case .terminal(let t) = prompt.requester {
                terminals.approve(k, label: t.info.app + (t.info.tty.map { " · \($0)" } ?? ""))
            }
        case (.agent(let k), .lasting(let lifetime, _)):
            let stored = scope.storedKey(for: k)!
            let (itemLabel, vaultLabel) = (prompt.target.title, prompt.target.vaultName)
            let grantedTo = stored.audience == .allAgents ? k.audience : nil
            do {
                switch authority {
                case .touchID(let context):
                    if let context { signingContext = context }
                    try store.approve(stored, lifetime: lifetime, sessionLabel: prompt.requester.labelTitle,
                                      grantedTo: grantedTo, itemLabel: itemLabel, vaultLabel: vaultLabel) { payload in
                        guard let signer else { throw NoApprovalKey() }
                        return try signer.sign(payload, context: context)
                    }
                case .device(let proof, let grant?):
                    try store.approve(stored, sessionLabel: prompt.requester.labelTitle, grantedTo: grantedTo, itemLabel: itemLabel,
                                      vaultLabel: vaultLabel, approvedAt: grant.approvedAt, expiresAt: grant.expiresAt, proof: proof)
                case .device(_, nil):
                    log.write("approved once, not remembered: the phone's reply carried no grant")
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
            if isApproved(key) { result = .approved(.touchID(nil), .once); done.signal(); return }
            let waiter: (Decision) -> Void = { result = $0; done.signal() }
            if pending[key] != nil {
                pending[key]!.append(waiter)
                return
            }
            pending[key] = [waiter]
            log.write("prompting: \(Self.describe(key)) op \(prompt.request.argv.joined(separator: " ")) → \(prompt.target.label)")
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
        case .agent(let k): return k.audience.logName
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

    private func agentPrompt(_ request: ProxyRequest, item: ItemRequest, target: ItemIdentity, session: AgentSession,
                             key: DialogKey, peer: pid_t, identity: SessionIdentity) -> ApprovalPrompt {
        let caller = CallerContext.from(chain: ProcessTree.ancestry(of: peer), agentPid: identity.agentPid)
        let requester = AgentRequester(session: session, label: label(request, peer: peer, agent: (session, identity.agentPid)),
                                       caller: caller, lastMessage: SessionInfo.lastAgentMessage(session),
                                       agentPid: identity.agentPid)
        return ApprovalPrompt(key: key, request: request, requester: .agent(requester), item: item, target: target,
                              peerPid: peer)
    }

    private func terminalPrompt(_ request: ProxyRequest, item: ItemRequest, target: ItemIdentity, key: DialogKey,
                                peer: pid_t, sid: pid_t) -> ApprovalPrompt {
        let info = TerminalInfo.from(chain: ProcessTree.ancestry(of: peer), sid: sid)
        let requester = TerminalRequester(info: info, label: label(request, peer: peer, agent: nil))
        return ApprovalPrompt(key: key, request: request, requester: .terminal(requester), item: item, target: target,
                              peerPid: peer)
    }

    /// Asks the configured label command about the caller (README, "Naming agents").
    private func label(_ request: ProxyRequest, peer: pid_t, agent: (session: AgentSession, pid: pid_t)?) -> RequesterLabel? {
        guard let labeler = OpProxyConfig.load(paths)?.requesterLabel else { return nil }
        var input: [String: Any] = ["environment": request.labelEnvironment ?? [:], "pid": Int(peer), "cwd": request.cwd]
        if let agent {
            input["agent"] = ["kind": agent.session.agent.rawValue, "sessionId": agent.session.sessionId, "pid": Int(agent.pid)]
        }
        return labeler.label(input)
    }

    // MARK: Which item a request means

    struct Unresolved: Error {
        let response: ProxyResponse
    }

    private let catalogLock = NSLock()
    private var catalogs: [[String]: (catalog: ItemCatalog, fetchedAt: Date)] = [:]
    /// Agents tend to ask for several things in a burst; a listing this fresh is reused.
    private static let catalogTTL: TimeInterval = 30

    /// The one item `item` names, worked out from `op item list` (which returns no secrets)
    /// by `ItemCatalog`'s rules. A miss in a cached listing is retried against a fresh one.
    private func resolve(_ item: ItemRequest, env: [String: String]) -> Result<ItemIdentity, Unresolved> {
        let listArgv = ["item", "list", "--format", "json"] + (item.includeArchive ? ["--include-archive"] : [])
            + (item.account.map { ["--account", $0] } ?? [])
        let cacheKey = listArgv + [env["OP_ACCOUNT"] ?? "", env["OP_INCLUDE_ARCHIVE"] ?? ""]
        var match = ItemCatalog.Match.none
        for fresh in [false, true] {
            let cached = fresh ? nil : catalogLock.withLock { catalogs[cacheKey] }
                .flatMap { Date().timeIntervalSince($0.fetchedAt) < Self.catalogTTL ? $0.catalog : nil }
            let catalog: ItemCatalog
            if let cached {
                catalog = cached
            } else {
                let listing = auth.run(listArgv, extraEnv: env, timeout: 90)
                guard listing.exitCode == 0 else { return .failure(Unresolved(response: listing)) }
                guard let parsed = try? ItemCatalog(json: listing.stdout) else {
                    return .failure(Unresolved(response: .failure("could not read `op item list` to find “\(item.item)”.")))
                }
                catalog = parsed
                catalogLock.withLock { catalogs[cacheKey] = (parsed, Date()) }
            }
            match = catalog.resolve(item: item.item, vault: item.vault)
            if match != .none || cached == nil { break }
        }
        let place = item.vault.map { " in vault “\($0)”" } ?? ""
        switch match {
        case .one(let found):
            return .success(found)
        case .none:
            return .failure(Unresolved(response: .failure(
                "no item matches “\(item.item)”\(place). opProxy finds an item by its ID or its exact title (in any case); "
                + "`op item list --format json` lists both.")))
        case .many(let found):
            let list = found.map { "\($0.itemId) (“\($0.title)” in \($0.vaultName))" }.joined(separator: ", ")
            return .failure(Unresolved(response: .failure(
                "“\(item.item)”\(place) matches \(found.count) items: \(list). Use the item's ID, or its vault, to pick one.")))
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
