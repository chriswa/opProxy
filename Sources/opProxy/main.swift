import AppKit
import Foundation
import OpProxyCore

// Peers (agents, the shim, the session holder) can vanish mid-conversation; a write to a
// closed socket or pipe must return EPIPE, not kill the process.
signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments
if (arguments[0] as NSString).lastPathComponent == "op" {
    Shim.run(Array(arguments.dropFirst()))
}

let usage = """
    opProxy — puts an approval dialog in front of agent 1Password CLI reads.

    Installed as `op` (a symlink to this binary), it proxies read-only commands from
    Claude Code, Codex and Cursor sessions through a daemon; everything else execs the
    real op unchanged.

    Usage:
      opProxy daemon                 Run the daemon (normally started by launchd)
      opProxy list                   Show active approvals
      opProxy revoke --all           Remove every approval
      opProxy revoke <session-id>    Remove one session's approvals
      opProxy status                 Daemon and 1Password authorization status
      opProxy refresh                Authorize a fresh 1Password session now (one prompt)
      opProxy disable | enable       Send every op call straight to 1Password, or back through opProxy
      opProxy devices                Show phones paired to approve requests
      opProxy unpair <key-id> | --all  Unpair a phone (by key ID or fingerprint prefix); ends its lasting approvals
      opProxy setup                  Open the Setup window
      opProxy pair-iphone            Open the iPhone app's pairing code
      opProxy install-agent          Install and start the background agent for this copy of opProxy

    """

func daemonStatus(_ message: DaemonMessage) -> DaemonStatus? {
    guard let fd = UnixSocket.connect(path: paths.socket.path) else { return nil }
    defer { close(fd) }
    guard let body = try? JSONEncoder().encode(message),
          UnixSocket.writeAll(fd, body + Data("\n".utf8)) else { return nil }
    return try? JSONDecoder().decode(DaemonStatus.self, from: UnixSocket.readToEnd(fd))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("opProxy: \(message)\n".utf8))
    exit(1)
}

let paths = Paths()

// Launched as an app (Finder, `open`, a login item) rather than as a command: the executable
// is run by its path inside the bundle with no arguments.
if arguments.count == 1, arguments[0].contains(".app/Contents/MacOS/"), let executable = Bundle.main.executablePath {
    LaunchAgent.startFromAppLaunch(paths: paths, executable: executable)
}

switch arguments.dropFirst().first {
case "daemon":
    do { try paths.ensureStateDir() } catch { fail("could not create \(paths.stateDir.path): \(error)") }
    let log = Log(url: paths.log)
    let local: LocalApprover
    if let scripted = TestKnobs.value("OPPROXY_TEST_APPROVER"), let decision = Decision(scripted: scripted) {
        local = ScriptedApprover(decision: decision, delay: Double(TestKnobs.value("OPPROXY_TEST_DELAY") ?? "") ?? 0, log: log)
    } else {
        local = DialogApprover()
    }
    let signer = makeApprovalSigner(paths: paths, log: log)
    let devices = makePairedDeviceStore(paths: paths, signer: signer)
    // Every request is also published for paired phones; the first answer wins.
    let feed = ApprovalFeed(log: log, devices: devices, confirmPairing:
        Pairing.confirmer(devices: devices, signer: signer, autoPair: TestKnobs.value("OPPROXY_TEST_AUTO_PAIR") != nil))
    let approver = FanoutApprover(local: local, feed: feed)
    guard let executable = Bundle.main.executablePath else { fail("cannot find my own executable") }
    let auth = AuthTracker(executable: executable, log: log,
                           pollInterval: Double(TestKnobs.value("OPPROXY_POLL_SECONDS") ?? "") ?? 60,
                           autoAuthorize: TestKnobs.value("OPPROXY_NO_AUTO_AUTH") == nil)
    let daemon = Daemon(paths: paths, approver: approver, log: log, auth: auth, signer: signer, devices: devices)
    let systemEvents = LockDiagnostics.logSystemEvents(to: log)
    // Attached before start(): the startup authorization is the first prompt it explains.
    let authContext = TestKnobs.value("OPPROXY_NO_MENU_BAR") == nil ? AuthContextPanel(expiresIn: AuthWindow.hardCap, log: log) : nil
    auth.promptObserver = authContext
    do { try daemon.start() } catch { fail("could not start: \(error)") }
    feed.authStatus = { (auth.current, auth.isRefreshing) }
    // CloudKit needs a build signed with the provisioning profile; others serve Spaceterm only.
    let cloud = CloudTransport.available ? CloudTransport(linksURL: paths.cloudLinks, log: log) : nil
    feed.start([FeedSocket(path: paths.approvalFeed, log: log)] + [cloud].compactMap { $0 })
    let pairing = cloud.map { CloudPairing(transport: $0, log: log) }
    daemon.onPairPhone = pairing.map { pairing in { pairing.start() } }
    daemon.onShowSetup = { SetupWindow.show(paths: paths, pairing: pairing) }
    if let file = TestKnobs.value("OPPROXY_TEST_CLOUD_PAIR"), let pairing {
        pairing.testPayloadFile = URL(fileURLWithPath: file)
        DispatchQueue.main.async { pairing.start() }
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let menuBar = TestKnobs.value("OPPROXY_NO_MENU_BAR") == nil ? MenuBarController(daemon: daemon, pairing: pairing, paths: paths) : nil
    withExtendedLifetime((menuBar, authContext, systemEvents)) { app.run() }

case "disable", "enable":
    do {
        try paths.setDisabled(arguments[1] == "disable")
        print(paths.isDisabled ? "opProxy disabled: op calls go straight to 1Password." : "opProxy enabled.")
    } catch { fail("could not update \(paths.disabledFlag.path): \(error)") }

case "keygen":
    // install.sh: prints this Mac's approval public key, creating the key on first run.
    do {
        try paths.ensureStateDir()
        print(try EnclaveSigner.publicKey(creatingAt: paths.approvalKey).base64EncodedString())
    } catch { fail("could not create the Secure Enclave approval key: \(error)") }

#if OPPROXY_TESTING
case "test-cloud-phone":
    CloudTestPhone.run(Array(arguments.dropFirst(2)), paths: paths)

case "render-dialog":
    DialogPreview.render(to: URL(fileURLWithPath: arguments.dropFirst(2).first { !$0.hasPrefix("-") } ?? "."),
                         onScreen: arguments.contains("--on-screen"))

case "test-feed-client":
    FeedTestClient.run(Array(arguments.dropFirst(2)))
#endif

case "session-holder":
    SessionHolder.run(paths: paths)

case "list":
    let signer = makeApprovalSigner(paths: paths)
    let store = makeApprovalStore(paths: paths, signer: signer, devices: makePairedDeviceStore(paths: paths, signer: signer))
    let approvals = store.active.sorted { $0.approvedAt < $1.approvedAt }
    if approvals.isEmpty { print("No active approvals.") }
    if !store.rejected.isEmpty { print("Ignoring \(store.rejected.count) entr\(store.rejected.count == 1 ? "y" : "ies") with invalid signatures.") }
    let f = DateFormatter()
    f.dateFormat = "MMM d HH:mm"
    for a in approvals {
        let label = a.sessionLabel.map { " “\($0)”" } ?? ""
        switch a.key.audience {
        case .session(let agent, let id): print("\(agent.displayName) \(id)\(label)")
        case .process(let agent, let instance): print("\(agent.displayName) process \(instance)\(label)")
        case .allAgents: print("All agents")
        }
        print("    \(a.label)  (item \(a.key.item.itemId), vault \(a.key.item.vaultId)\(a.key.item.account.map { ", account \($0)" } ?? ""))")
        print("    approved \(f.string(from: a.approvedAt)), expires \(f.string(from: a.expiresAt))")
    }

case "revoke":
    guard let target = arguments.dropFirst(2).first else { fail("usage: opProxy revoke --all | <session-id>") }
    let signer = makeApprovalSigner(paths: paths)
    let store = makeApprovalStore(paths: paths, signer: signer, devices: makePairedDeviceStore(paths: paths, signer: signer))
    do {
        let n = try store.revoke { target == "--all" || $0.key.audience.sessionId == target }
        print("Revoked \(n) approval\(n == 1 ? "" : "s").")
    } catch { fail("could not update \(paths.approvals.path): \(error)") }

case "devices":
    let devices = makePairedDeviceStore(paths: paths, signer: makeApprovalSigner(paths: paths))
    let f = DateFormatter()
    f.dateFormat = "MMM d HH:mm"
    if devices.devices.isEmpty { print("No paired phones.") }
    if !devices.rejected.isEmpty { print("Ignoring \(devices.rejected.count) entr\(devices.rejected.count == 1 ? "y" : "ies") with invalid signatures.") }
    for d in devices.devices {
        print("\(d.name)  \(d.fingerprint)  paired \(f.string(from: d.pairedAt))")
        print("    key ID \(d.keyId)")
    }

case "unpair":
    guard let target = arguments.dropFirst(2).first else { fail("usage: opProxy unpair --all | <key-id-prefix>") }
    let devices = makePairedDeviceStore(paths: paths, signer: makeApprovalSigner(paths: paths))
    // A fingerprint as shown ("ab12 cd34") is a key ID prefix once the spaces are gone.
    let prefix = target.lowercased().replacingOccurrences(of: " ", with: "")
    let matches = devices.devices.filter { target == "--all" || $0.keyId.hasPrefix(prefix) }
    if target != "--all", matches.count > 1 { fail("\(target) matches \(matches.count) phones; give more of the key ID") }
    do {
        let ids = Set(matches.map(\.keyId))
        let n = try devices.unpair { target == "--all" || ids.contains($0.keyId) }
        print("Unpaired \(n) phone\(n == 1 ? "" : "s"). Approvals made on \(n == 1 ? "it" : "them") no longer verify.")
    } catch { fail("could not update \(paths.pairedDevices.path): \(error)") }

case "install-agent":
    // install.sh: what opening the app does on a Mac with no agent yet.
    guard let executable = Bundle.main.executablePath else { fail("cannot find my own executable") }
    Setup.linkCommands(to: executable)
    do { try LaunchAgent.install(executable: executable, paths: paths) } catch { fail("could not install the background agent: \(error)") }

case "setup":
    guard daemonStatus(.showSetup) != nil else { fail("the opProxy daemon isn't running; open opProxy.app") }

case "pair-iphone":
    guard let status = daemonStatus(.pairPhone) else { fail("the opProxy daemon isn't running") }
    if let error = status.error { fail(error) }
    print("The pairing code is open on the Mac. Scan it with the opProxy iPhone app.")

case "status", "refresh":
    let refresh = arguments[1] == "refresh"
    guard let status = daemonStatus(refresh ? .refresh : .status) else {
        print("Daemon: not running — agents fall back to the real op")
        exit(1)
    }
    let clock = DateFormatter()
    clock.dateFormat = "MMM d h:mm a"
    if let remaining = status.auth.remaining(), let expiresAt = status.auth.expiresAt {
        print("1Password: authorized, \(Duration.long(remaining)) left (expires \(clock.string(from: expiresAt)))")
    } else {
        print("1Password: not authorized")
    }
    print("Active approvals: \(status.activeApprovals)")
    if paths.isDisabled { print("Proxying: disabled (opProxy enable to turn back on)") }
    if let error = status.error { fail("refresh failed: \(error)") }

case "-h", "--help", "help", nil:
    print(usage)

default:
    fail("unknown command \(arguments[1])\n\n\(usage)")
}
