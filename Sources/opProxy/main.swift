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
    opProxy — approves agent 1Password CLI requests once per session and command.

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
if arguments.count == 1, arguments[0].contains(".app/Contents/MacOS/") {
    LaunchAgent.startFromAppLaunch(paths: paths)
}

switch arguments.dropFirst().first {
case "daemon":
    do { try paths.ensureStateDir() } catch { fail("could not create \(paths.stateDir.path): \(error)") }
    let log = Log(url: paths.log)
    let approver: Approver
    if let scripted = TestKnobs.value("OPPROXY_TEST_APPROVER"), let decision = Decision(scripted: scripted) {
        approver = ScriptedApprover(decision: decision, delay: Double(TestKnobs.value("OPPROXY_TEST_DELAY") ?? "") ?? 0, log: log)
    } else {
        approver = DialogApprover()
    }
    guard let executable = Bundle.main.executablePath else { fail("cannot find my own executable") }
    let auth = AuthTracker(executable: executable, log: log,
                           pollInterval: Double(TestKnobs.value("OPPROXY_POLL_SECONDS") ?? "") ?? 60,
                           autoAuthorize: TestKnobs.value("OPPROXY_NO_AUTO_AUTH") == nil)
    let daemon = Daemon(paths: paths, approver: approver, log: log, auth: auth)
    // Attached before start(): the startup authorization is the first prompt it explains.
    let authContext = TestKnobs.value("OPPROXY_NO_MENU_BAR") == nil ? AuthContextPanel(expiresIn: AuthWindow.hardCap, log: log) : nil
    auth.promptObserver = authContext
    do { try daemon.start() } catch { fail("could not start: \(error)") }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let menuBar = TestKnobs.value("OPPROXY_NO_MENU_BAR") == nil ? MenuBarController(daemon: daemon) : nil
    withExtendedLifetime((menuBar, authContext)) { app.run() }

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
case "render-dialog":
    DialogPreview.render(to: URL(fileURLWithPath: arguments.dropFirst(2).first { !$0.hasPrefix("-") } ?? "."),
                         onScreen: arguments.contains("--on-screen"))
#endif

case "session-holder":
    SessionHolder.run(paths: paths)

case "list":
    let store = makeApprovalStore(paths: paths, signer: makeApprovalSigner(paths: paths))
    let approvals = store.active.sorted { $0.approvedAt < $1.approvedAt }
    if approvals.isEmpty { print("No active approvals.") }
    if !store.rejected.isEmpty { print("Ignoring \(store.rejected.count) entr\(store.rejected.count == 1 ? "y" : "ies") with invalid signatures.") }
    let f = DateFormatter()
    f.dateFormat = "MMM d HH:mm"
    for a in approvals {
        let label = a.sessionLabel.map { " “\($0)”" } ?? ""
        print("\(a.key.agent.displayName) \(a.key.sessionId)\(label)")
        let env = a.key.env.map { "\($0.key)=\($0.value) " }.sorted().joined()
        print("    \(env)op \(a.key.argv.joined(separator: " "))")
        print("    approved \(f.string(from: a.approvedAt)), expires \(f.string(from: a.expiresAt))")
    }

case "revoke":
    guard let target = arguments.dropFirst(2).first else { fail("usage: opProxy revoke --all | <session-id>") }
    let store = makeApprovalStore(paths: paths, signer: makeApprovalSigner(paths: paths))
    do {
        let n = try store.revoke { target == "--all" || $0.key.sessionId == target }
        print("Revoked \(n) approval\(n == 1 ? "" : "s").")
    } catch { fail("could not update \(paths.approvals.path): \(error)") }

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
