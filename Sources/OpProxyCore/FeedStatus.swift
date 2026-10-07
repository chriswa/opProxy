import Foundation

/// The 1Password authorization as the approval feed's `status` message reports it to phones
/// (APPROVAL_FEED.md, "Provider status"): authorized until when, or since when it isn't.
public struct FeedStatus: Equatable {
    public let ok: Bool
    /// While `ok`: when the authorization runs out at the latest (1Password's 12-hour cap).
    public let until: Date?
    /// When the authorization started, or when it was lost.
    public let since: Date
    public let detail: String

    public static let label = "1Password"
    public static let lostTitle = "1Password authorization lost"

    /// `lostSince`: when the feed last saw the authorization go, used while it's gone.
    /// `prompting`: 1Password's prompt may be on screen at the Mac right now.
    public init(_ window: AuthWindow, prompting: Bool, lostSince: Date, now: Date = Date()) {
        if window.remaining(at: now) != nil, let authorizedAt = window.authorizedAt {
            ok = true
            until = window.expiresAt
            since = authorizedAt
            detail = ""
        } else {
            ok = false
            until = nil
            since = lostSince
            detail = prompting ? "1Password is asking for authorization on the Mac."
                               : "The next agent request will prompt 1Password on the Mac."
        }
    }

    public var json: [String: Any] {
        func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
        var out: [String: Any] = ["ok": ok, "label": Self.label, "since": ms(since)]
        if let until { out["until"] = ms(until) }
        if !ok {
            out["title"] = Self.lostTitle
            out["detail"] = detail
        }
        return out
    }
}
