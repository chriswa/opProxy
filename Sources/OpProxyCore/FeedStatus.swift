import Foundation

/// The 1Password authorization as the approval feed's `status` message reports it to phones
/// (APPROVAL_FEED.md, "Status"): authorized since when, or since when it isn't.
public struct FeedStatus: Equatable {
    public let ok: Bool
    /// When the authorization started, or when it was lost.
    public let since: Date
    public let detail: String

    public static let label = "1Password"
    public static let lostTitle = "1Password authorization lost"

    /// `lostSince`: when the feed last saw the authorization go, used while it's gone.
    /// `prompting`: 1Password's prompt may be on screen at the Mac right now.
    public init(_ window: AuthWindow, prompting: Bool, lostSince: Date) {
        if window.signedIn, let authorizedAt = window.authorizedAt {
            ok = true
            since = authorizedAt
            detail = ""
        } else {
            ok = false
            since = lostSince
            detail = prompting ? "1Password is asking for authorization on the Mac."
                               : "The next agent request will prompt 1Password on the Mac."
        }
    }

    public var json: [String: Any] {
        var out: [String: Any] = ["ok": ok, "label": Self.label, "since": Int64(since.timeIntervalSince1970 * 1000)]
        if !ok {
            out["title"] = Self.lostTitle
            out["detail"] = detail
        }
        return out
    }
}
