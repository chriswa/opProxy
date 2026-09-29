import Foundation

/// The daemon's 1Password authorization as the menu bar sees it. 1Password doesn't report
/// expiry, so the window is counted from when opProxy first saw the session signed in.
public struct AuthWindow: Codable, Equatable {
    /// 1Password ends every CLI authorization this long after it starts.
    public static let hardCap: TimeInterval = 12 * 60 * 60

    public let signedIn: Bool
    public let authorizedAt: Date?

    public init(signedIn: Bool, authorizedAt: Date?) {
        self.signedIn = signedIn
        self.authorizedAt = authorizedAt
    }

    public var expiresAt: Date? { authorizedAt?.addingTimeInterval(Self.hardCap) }

    /// Seconds left, or nil when `whoami` fails or the 12 hours are up.
    public func remaining(at now: Date = Date()) -> TimeInterval? {
        guard signedIn, let expiresAt, expiresAt > now else { return nil }
        return expiresAt.timeIntervalSince(now)
    }
}

public enum Duration {
    /// Menu bar label, rounded to the nearest unit: "12h" from 11h 30m up, minutes below
    /// 59m 30s, "<1m" under 30 seconds.
    public static func short(_ seconds: TimeInterval) -> String {
        if seconds < 30 { return "<1m" }
        if seconds < 59.5 * 60 { return "\(Int((seconds / 60).rounded()))m" }
        return "\(Int((seconds / 3600).rounded()))h"
    }

    /// Menu text: "11h 32m", "32m", "<1m".
    public static func long(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "<1m" }
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
