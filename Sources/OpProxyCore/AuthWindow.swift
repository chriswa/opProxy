import Foundation

/// The daemon's 1Password authorization as the menu bar sees it. It lasts until 1Password
/// ends it (the app locks, quits or updates), so it's shown as how long it has held,
/// counted from when opProxy's session was authorized.
public struct AuthWindow: Codable, Equatable {
    public let signedIn: Bool
    public let authorizedAt: Date?

    public init(signedIn: Bool, authorizedAt: Date?) {
        self.signedIn = signedIn
        self.authorizedAt = authorizedAt
    }

    /// How long it has been authorized, or nil while it isn't.
    public func age(at now: Date = Date()) -> TimeInterval? {
        guard signedIn, let authorizedAt else { return nil }
        return max(0, now.timeIntervalSince(authorizedAt))
    }
}

extension Duration {
    /// Menu text: "11h 32m", "32m", "<1m".
    public static func long(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "<1m" }
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
