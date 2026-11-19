import Foundation
import OpProxyCore

/// Why opProxy is asking 1Password for authorization; shown beside 1Password's prompt.
enum AuthReason: String {
    case startup = "opProxy just started."
    case expired = "The previous authorization ended (1Password locked, quit or updated)."
    case manual = "You chose Refresh Now."
    case request = "A request needs 1Password, and opProxy isn't authorized yet."
    case pairingKey = "opProxy is saving the iPhone you're pairing's key in 1Password."
    case unpairing = "opProxy is deleting an unpaired iPhone's key from 1Password."
}

/// Shows context while 1Password's own prompt may be on screen.
protocol AuthPromptObserver: AnyObject {
    /// Called (on any queue) just before a call that may raise 1Password's prompt; returns a
    /// function to call once it has finished.
    func authorizationMayPrompt(_ reason: AuthReason) -> () -> Void
}

/// Owns the 1Password helper (`SDKSession`) whose authorization every request runs under, and
/// tracks it for the menu bar. 1Password ends an SDK authorization only when the app locks,
/// quits or restarts, or after 10 idle minutes, which the heartbeat (a vault listing every
/// minute, which never prompts) prevents. How long one lasts is logged, hourly and when it ends.
final class AuthTracker {
    let helper: HelperSpec
    let log: Log
    let pollInterval: TimeInterval
    /// Which account to authorize: the one in the config, or the only one `op` knows.
    let account: () -> Result<OnePasswordAccount, HelperError>
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
    /// Held while authorizing, so concurrent requests wait for one prompt instead of each raising one.
    private let authorizing = NSLock()
    private var session: SDKSession?
    private var sessionAccount: OnePasswordAccount?
    private var window = AuthWindow(signedIn: false, authorizedAt: nil)
    private var refreshing = false
    private var hoursLogged = 0
    private var unreachable = false
    private var timer: DispatchSourceTimer?

    init(helper: HelperSpec, account: @escaping () -> Result<OnePasswordAccount, HelperError>, log: Log,
         pollInterval: TimeInterval, autoAuthorize: Bool) {
        self.helper = helper
        self.account = account
        self.log = log
        self.pollInterval = pollInterval
        self.autoAuthorize = autoAuthorize
    }

    var current: AuthWindow { lock.withLock { window } }
    /// A refresh is waiting on 1Password, whose prompt may be on screen.
    var isRefreshing: Bool { lock.withLock { refreshing } }

    /// "5h 12m", for log lines about requests.
    var ageDescription: String {
        current.age().map { Duration.long($0) } ?? "not authorized"
    }

    func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [self] in heartbeat() }
        timer.resume()
        self.timer = timer
        autoRefresh(.startup)
    }

    private func autoRefresh(_ reason: AuthReason) {
        guard autoAuthorize, !lock.withLock({ autoSuspended || refreshing }) else { return }
        DispatchQueue.global().async { [self] in
            // Another authorization under way answers for this one.
            guard authorizing.try() else { return }
            defer { authorizing.unlock() }
            if authorized() == nil, authorize(reason: reason) != nil { lock.withLock { autoSuspended = true } }
        }
    }

    /// Keeps the authorization from idling out, and notices when 1Password has ended it.
    private func heartbeat() {
        guard let (s, _) = lock.withLock({ session.flatMap { s in sessionAccount.map { (s, $0) } } }) else {
            autoRefresh(.expired)
            return
        }
        switch s.vaults() {
        case .success:
            let (age, reached, wasUnreachable): (TimeInterval, Bool, Bool) = lock.withLock {
                let age = window.age() ?? 0
                let hours = Int(age / 3600)
                defer { hoursLogged = max(hoursLogged, hours); unreachable = false }
                return (age, hours > hoursLogged, unreachable)
            }
            if wasUnreachable { log.write("1Password reachable again; authorized \(Duration.long(age)) ago") }
            if reached { log.write("1Password authorization still good after \(Duration.long(age)) (helper \(s.pid))") }
        case .failure(let failure):
            observe(failure, from: s)
        }
    }

    /// The authorized session, for one request; asks 1Password first if there isn't one.
    func client(reason: AuthReason = .request) -> Result<(OnePassword, OnePasswordAccount), SDK.Failure> {
        if let found = authorized() { return .success(found) }
        authorizing.lock()
        defer { authorizing.unlock() }
        // Another request may have authorized while this one waited.
        if let found = authorized() { return .success(found) }
        if let error = authorize(reason: reason) { return .failure(SDK.Failure(.unauthorized, error)) }
        return authorized().map { .success($0) } ?? .failure(SDK.Failure(.unauthorized, "1Password did not authorize opProxy"))
    }

    private func authorized() -> (OnePassword, OnePasswordAccount)? {
        lock.withLock {
            guard window.signedIn, let session, session.isUsable, let sessionAccount else { return nil }
            return (TrackedClient(session: session, tracker: self), sessionAccount)
        }
    }

    /// Authorizes a fresh session (one 1Password prompt), then moves all traffic to it. The
    /// old session keeps serving until then, so nothing fails while the prompt is up.
    func refresh(reason: AuthReason = .manual) -> String? {
        guard authorizing.try() else { return "a refresh is already waiting for 1Password" }
        defer { authorizing.unlock() }
        return authorize(reason: reason)
    }

    /// Call holding `authorizing`.
    private func authorize(reason: AuthReason) -> String? {
        lock.withLock { refreshing = true }
        defer { lock.withLock { refreshing = false } }
        let chosen: OnePasswordAccount
        switch account() {
        case .success(let a): chosen = a
        case .failure(let reason):
            log.write("refresh failed: \(reason)")
            return reason.description
        }
        let fresh: SDKSession
        do { fresh = try SDKSession(helper) } catch {
            log.write("refresh failed: could not start the 1Password helper: \(error)")
            return "could not start the 1Password helper: \(error)"
        }
        let dismiss = promptObserver?.authorizationMayPrompt(reason)
        let result = fresh.authorize(account: chosen.accountUUID, version: MacIdentity.appVersion)
        dismiss?()
        if case .failure(let failure) = result {
            fresh.close()
            log.write("refresh failed: \(failure.message) (\(LockDiagnostics.summary()))")
            return failure.message
        }
        let (old, changed) = lock.withLock { () -> (SDKSession?, AuthWindow) in
            let old = session
            autoSuspended = false
            session = fresh
            sessionAccount = chosen
            hoursLogged = 0
            unreachable = false
            window = AuthWindow(signedIn: true, authorizedAt: Date())
            return (old, window)
        }
        old?.close()
        log.write("refreshed: helper \(old.map { String($0.pid) } ?? "-") → \(fresh.pid); 1Password authorized for \(chosen.email) "
                  + "(\(chosen.url)): \(reason.rawValue)")
        notify(changed)
        return nil
    }

    /// A call through `session` failed: 1Password may have ended its authorization.
    fileprivate func observe(_ failure: SDK.Failure, from s: SDKSession) {
        switch failure.kind {
        case .unauthorized:
            let ended: (AuthWindow, TimeInterval?)? = lock.withLock {
                guard s === session, window.signedIn else { return nil }
                let age = window.age()
                window = AuthWindow(signedIn: false, authorizedAt: nil)
                session = nil
                return (window, age)
            }
            guard let (changed, age) = ended else { return }
            s.close()
            log.write("1Password authorization ended after \(age.map { Duration.long($0) } ?? "?"): \(failure.message) "
                      + "(\(LockDiagnostics.summary()))")
            notify(changed)
            autoRefresh(.expired)
        case .network:
            let first = lock.withLock { () -> Bool in
                defer { unreachable = true }
                return !unreachable && s === session
            }
            if first { log.write("1Password unreachable, keeping the authorization: \(failure.message)") }
        case .failed:
            break
        }
    }

    private func notify(_ window: AuthWindow) {
        DispatchQueue.main.async { [self] in onChange?(window) }
    }
}

/// A session as requests use it: every failure is reported to the tracker, so a request
/// that finds the authorization gone ends it for everyone.
private final class TrackedClient: OnePassword {
    let session: SDKSession
    weak var tracker: AuthTracker?

    init(session: SDKSession, tracker: AuthTracker) {
        self.session = session
        self.tracker = tracker
    }

    private func track<T>(_ result: Result<T, SDK.Failure>) -> Result<T, SDK.Failure> {
        if case .failure(let failure) = result { tracker?.observe(failure, from: session) }
        return result
    }

    func vaults() -> Result<[SDK.VaultOverview], SDK.Failure> { track(session.vaults()) }
    func vault(_ vaultId: String) -> Result<SDK.VaultOverview, SDK.Failure> { track(session.vault(vaultId)) }
    func items(vaultId: String, archived: Bool) -> Result<[SDK.ItemOverview], SDK.Failure> {
        track(session.items(vaultId: vaultId, archived: archived))
    }
    func item(vaultId: String, itemId: String) -> Result<SDK.Item, SDK.Failure> { track(session.item(vaultId: vaultId, itemId: itemId)) }
    func resolve(_ reference: String) -> Result<String, SDK.Failure> { track(session.resolve(reference)) }
    func file(vaultId: String, itemId: String, attributes: JSONValue) -> Result<Data, SDK.Failure> {
        track(session.file(vaultId: vaultId, itemId: itemId, attributes: attributes))
    }
    func create(_ params: SDK.ItemCreate) -> Result<SDK.Item, SDK.Failure> { track(session.create(params)) }
    func put(_ item: SDK.Item) -> Result<SDK.Item, SDK.Failure> { track(session.put(item)) }
    func delete(vaultId: String, itemId: String) -> Result<Void, SDK.Failure> { track(session.delete(vaultId: vaultId, itemId: itemId)) }
    func archive(vaultId: String, itemId: String) -> Result<Void, SDK.Failure> { track(session.archive(vaultId: vaultId, itemId: itemId)) }
}

/// Which account opProxy authorizes, from `op account list` (which never prompts): the one
/// the config names, else the only one.
enum AccountChoice {
    static func resolve(configured: String?, listing: ProxyResponse) -> Result<OnePasswordAccount, HelperError> {
        guard listing.exitCode == 0,
              let accounts = try? JSONDecoder().decode([OnePasswordAccount].self, from: listing.stdout) else {
            let error = String(decoding: listing.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(HelperError("could not list 1Password accounts with `op account list`: \(error.isEmpty ? "op exited \(listing.exitCode)" : error)"))
        }
        if let configured {
            return accounts.first { $0.matches(configured) }.map { .success($0) }
                ?? .failure(HelperError("no 1Password account matches “\(configured)” from ~/.opProxy/config.json"))
        }
        switch accounts.count {
        case 0: return .failure(HelperError("the 1Password app has no accounts signed in"))
        case 1: return .success(accounts[0])
        default:
            return .failure(HelperError("1Password has \(accounts.count) accounts: name the one opProxy uses as \"account\" in ~/.opProxy/config.json"))
        }
    }
}
