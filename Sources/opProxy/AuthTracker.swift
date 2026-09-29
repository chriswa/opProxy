import Foundation
import OpProxyCore

/// Why opProxy is asking 1Password for authorization; shown beside 1Password's prompt.
enum AuthReason: String {
    case startup = "opProxy just started."
    case expired = "The previous authorization ended (1Password locked or ended it)."
    case capReached = "The previous authorization reached 1Password's 12-hour limit."
    case manual = "You chose Refresh Now."
    case request = "A request needs 1Password, and opProxy isn't authorized yet."
}

/// Shows context while 1Password's own prompt may be on screen.
protocol AuthPromptObserver: AnyObject {
    /// Called (on any queue) just before an `op` call that may raise 1Password's prompt;
    /// returns a function to call once it has finished.
    func authorizationMayPrompt(_ reason: AuthReason) -> () -> Void
}

/// Owns the session holder that runs `op`, and tracks its 1Password authorization window
/// for the menu bar. `op whoami` never prompts, so polling it is safe, and it also counts as
/// activity, which stops 1Password's 10-minute idle timeout.
final class AuthTracker {
    let executable: String
    let log: Log
    let pollInterval: TimeInterval
    /// Called on the main queue whenever the window changes.
    var onChange: ((AuthWindow) -> Void)?
    weak var promptObserver: AuthPromptObserver?
    /// Ask 1Password up front (at startup, and when an authorization ends) rather than on the
    /// next request. Off in tests.
    let autoAuthorize: Bool
    /// Set when you decline an automatic prompt, so it doesn't reappear until you refresh or a
    /// request needs it.
    private var autoSuspended = false

    private let lock = NSLock()
    private var session: OpSession?
    private var window = AuthWindow(signedIn: false, authorizedAt: nil)
    private var refreshing = false
    private var timer: DispatchSourceTimer?

    init(executable: String, log: Log, pollInterval: TimeInterval, autoAuthorize: Bool) {
        self.executable = executable
        self.log = log
        self.pollInterval = pollInterval
        self.autoAuthorize = autoAuthorize
    }

    var current: AuthWindow { lock.withLock { window } }

    func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now(), repeating: pollInterval)
        timer.setEventHandler { [self] in
            if let s = try? currentSession() { probe(s) }
            // 1Password should end it at 12 hours; don't wait to find out.
            let w = current
            if w.signedIn, w.remaining() == nil { autoRefresh(.capReached) }
        }
        timer.resume()
        self.timer = timer
        autoRefresh(.startup)
    }

    private func autoRefresh(_ reason: AuthReason) {
        guard autoAuthorize, !lock.withLock({ autoSuspended || refreshing }) else { return }
        DispatchQueue.global().async { [self] in
            if refresh(reason: reason) != nil { lock.withLock { autoSuspended = true } }
        }
    }

    func run(_ argv: [String], extraEnv: [String: String], timeout: TimeInterval = 300) -> ProxyResponse {
        let s: OpSession
        do { s = try currentSession() } catch {
            return .failure("could not start the 1Password session helper: \(error)")
        }
        // Unauthorized, so this may raise 1Password's prompt: explain it alongside.
        let dismiss = argv.first != "whoami" && !current.signedIn ? promptObserver?.authorizationMayPrompt(.request) : nil
        let response = s.run(argv, extraEnv: extraEnv, timeout: timeout)
        dismiss?()
        if argv == ["whoami"] {
            update(signedIn: response.exitCode == 0, session: s)
        } else if !current.signedIn {
            // This run may have raised 1Password's prompt and authorized the session.
            probe(s)
        }
        return response
    }

    /// Authorizes a fresh session (one 1Password prompt), then moves all traffic to it. The
    /// old session keeps serving until then, so nothing fails while the prompt is up.
    func refresh(reason: AuthReason = .manual) -> String? {
        let started: Bool = lock.withLock {
            if refreshing { return false }
            refreshing = true
            return true
        }
        guard started else { return "a refresh is already waiting for 1Password" }
        defer { lock.withLock { refreshing = false } }
        let fresh: OpSession
        do { fresh = try OpSession(executable: executable) } catch {
            return "could not start a session helper: \(error)"
        }
        let dismiss = promptObserver?.authorizationMayPrompt(reason)
        let result = fresh.run(["vault", "list", "--format", "json"], extraEnv: [:], timeout: 120)
        dismiss?()
        guard result.exitCode == 0 else {
            fresh.close()
            let reason = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            log.write("refresh failed: \(reason)")
            return reason.isEmpty ? "1Password did not authorize the new session" : reason
        }
        let (old, changed) = lock.withLock { () -> (OpSession?, AuthWindow) in
            let old = session
            autoSuspended = false
            session = fresh
            window = AuthWindow(signedIn: true, authorizedAt: Date())
            return (old, window)
        }
        old?.close()
        log.write("refreshed: session helper \(old.map { String($0.pid) } ?? "-") → \(fresh.pid); expires \(format(changed.expiresAt))")
        notify(changed)
        return nil
    }

    private func currentSession() throws -> OpSession {
        try lock.withLock {
            if let session, session.isUsable { return session }
            let s = try OpSession(executable: executable)
            if session != nil { log.write("session helper exited; started \(s.pid)") }
            session = s
            window = AuthWindow(signedIn: false, authorizedAt: nil)
            return s
        }
    }

    private func probe(_ s: OpSession) {
        update(signedIn: s.run(["whoami"], extraEnv: [:], timeout: 10).exitCode == 0, session: s)
    }

    private func update(signedIn: Bool, session s: OpSession) {
        let changed: AuthWindow? = lock.withLock {
            guard s === session, signedIn != window.signedIn else { return nil }
            window = AuthWindow(signedIn: signedIn, authorizedAt: signedIn ? Date() : nil)
            return window
        }
        guard let changed else { return }
        log.write(signedIn ? "1Password authorized; expires \(format(changed.expiresAt))" : "1Password authorization ended")
        notify(changed)
        if signedIn { lock.withLock { autoSuspended = false } } else { autoRefresh(.expired) }
    }

    private func notify(_ window: AuthWindow) {
        DispatchQueue.main.async { [self] in onChange?(window) }
    }

    private func format(_ date: Date?) -> String {
        guard let date else { return "-" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
