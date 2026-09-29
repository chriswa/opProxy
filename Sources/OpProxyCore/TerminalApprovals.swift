import Darwin
import Foundation

/// A terminal tab (or any other non-agent caller), identified the way 1Password identifies
/// it: by Unix session. The session leader's start time guards against a reused session ID.
public struct TerminalKey: Hashable, CustomStringConvertible {
    public let sid: pid_t
    public let leaderStart: Double

    public init(sid: pid_t, leaderStart: Double) {
        self.sid = sid
        self.leaderStart = leaderStart
    }

    public static func of(pid: pid_t) -> TerminalKey? {
        let sid = getsid(pid)
        guard sid > 0 else { return nil }
        return TerminalKey(sid: sid, leaderStart: ProcessTree.entry(sid)?.startTime ?? 0)
    }

    public var description: String { "session \(sid)" }
}

/// Approvals for terminal tabs, matching 1Password's own CLI authorization: one approval
/// covers every read from the tab until it goes unused for `idle`, and never beyond `cap`.
/// Kept in memory only; a daemon restart ends them, as closing the tab ends 1Password's.
public final class TerminalApprovals {
    public static let defaultIdle: TimeInterval = 10 * 60
    public static let cap: TimeInterval = 12 * 60 * 60

    public struct Entry: Equatable {
        public let key: TerminalKey
        public let approvedAt: Date
        public let lastUsed: Date
        /// e.g. "iTerm · ttys012", for the menu.
        public let label: String
    }

    public let idle: TimeInterval
    private let now: () -> Date
    private var approvals: [TerminalKey: Entry] = [:]

    public init(idle: TimeInterval = TerminalApprovals.defaultIdle, now: @escaping () -> Date = Date.init) {
        self.idle = idle
        self.now = now
    }

    public func approve(_ key: TerminalKey, label: String) {
        let t = now()
        approvals[key] = Entry(key: key, approvedAt: t, lastUsed: t, label: label)
    }

    /// Unexpired approvals.
    public var active: [Entry] {
        let t = now()
        return approvals.values.filter { isLive($0, at: t) }
    }

    public func revoke(_ key: TerminalKey) { approvals.removeValue(forKey: key) }

    public func revokeAll() { approvals.removeAll() }

    private func isLive(_ e: Entry, at t: Date) -> Bool {
        t.timeIntervalSince(e.lastUsed) < idle && t.timeIntervalSince(e.approvedAt) < Self.cap
    }

    /// Whether `key` is approved; if so, counts this as use, restarting the idle clock.
    public func use(_ key: TerminalKey) -> Bool {
        let t = now()
        guard let e = approvals[key], isLive(e, at: t) else {
            approvals.removeValue(forKey: key)
            return false
        }
        approvals[key] = Entry(key: key, approvedAt: e.approvedAt, lastUsed: t, label: e.label)
        return true
    }

}

/// What the dialog can say about a non-agent caller, from its process tree.
public struct TerminalInfo: Equatable {
    /// "iTerm", "Ghostty", "Spaceterm", or the outermost process when it isn't a terminal.
    public let app: String
    public let tty: String?
    public let sid: pid_t
    /// The caller and its ancestors up to the tab's shell, nearest first: "pid  argv".
    public let chain: [String]

    public init(app: String, tty: String?, sid: pid_t, chain: [String]) {
        self.app = app
        self.tty = tty
        self.sid = sid
        self.chain = chain
    }

    /// `chain` is nearest first, as from `ProcessTree.ancestry`.
    public static func from(chain: [ProcessEntry], sid: pid_t) -> TerminalInfo {
        // Up to and including the session leader (the tab's shell).
        let inSession = chain.prefix { $0.pid != sid } + chain.filter { $0.pid == sid }.prefix(1)
        let lines = inSession.map { e -> String in
            let command = e.argv.isEmpty ? e.executable : e.argv.joined(separator: " ")
            return "\(e.pid)  " + String(command.prefix(240))
        }
        return TerminalInfo(app: appName(chain), tty: chain.first?.tty, sid: sid, chain: lines)
    }

    static func appName(_ chain: [ProcessEntry]) -> String {
        for e in chain {
            let paths = [e.executable] + e.argv.prefix(1)
            if paths.contains(where: { $0.lowercased().contains("spaceterm") }) { return "Spaceterm" }
            for path in paths {
                if let range = path.range(of: ".app/") {
                    return ((String(path[..<range.lowerBound])) as NSString).lastPathComponent
                }
            }
        }
        return chain.last?.name ?? "unknown process"
    }
}
