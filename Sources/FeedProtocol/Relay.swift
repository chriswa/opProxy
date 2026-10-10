import Foundation

/// The version of the approval feed's messages between a Mac and a phone (APPROVAL_FEED.md),
/// sent in the Mac's `hello`. The phone compares this, not app versions, so a Mac running its
/// own build works with the released phone app. Raise it only for a change the other side
/// would misread; a field it can ignore needs no change.
public enum FeedProtocolVersion {
    public static let current = 1
}

/// The version of the commands and events below, separate from the app version: a self-built
/// opProxy can run with a released relay, so they check this instead. Raise it only for a
/// change the other side would misread (a renamed or reshaped case, or one it can't do
/// without); adding a case one side may ignore needs no change.
public enum RelayProtocol {
    public static let version = 1
}

/// What the opProxy daemon and opProxy iCloud Relay say to each other. The daemon starts the
/// relay as its child, only while it has an iPhone to talk to, and they exchange one JSON
/// value per line on the relay's stdin and stdout. The relay is the only part signed for
/// CloudKit; it keeps each linked zone's records matching what it's told and reports what
/// phones write. Every feed field it handles is already sealed with that pairing's key
/// (`SealedField`), so it can't read a request or forge an answer.
public enum RelayCommand: Codable, Equatable {
    /// Serve a phone's zone: `owner` is the zone owner's record name, `shared` when it's in
    /// the shared database (the phone is on another Apple ID). The zone's records are written
    /// in full on the next pass.
    case link(zone: String, owner: String, shared: Bool)
    case unlink(zone: String)
    /// The record `name` in `zone` should hold these fields (field → value); `put` replaces
    /// them all.
    case put(zone: String, name: String, type: String, fields: [String: String])
    case delete(zone: String, name: String)
    /// Answers the inbox record `name` (an `inbox` event) by setting its response field.
    case respond(zone: String, name: String, response: String)
    /// Check for phone writes every second (something's pending) or every 30.
    case pace(quick: Bool)
    /// Asks for an `account` event.
    case account
    /// Watches the public database for the pairing rendezvous record `name` until `until`
    /// (ms since 1970), then sends a `rendezvous` event.
    case watchRendezvous(name: String, until: Int64)
    case stopRendezvous
    /// Joins the share a phone invited this Mac's iCloud user to; answered by `joined`.
    case join(share: URL)
}

public enum RelayEvent: Codable, Equatable {
    /// Sent once at start, with the relay's app version and `RelayProtocol.version`; the
    /// daemon then sends every link and record afresh, if it speaks the same protocol.
    case ready(version: String, protocolVersion: Int)
    /// This Mac's iCloud user, as the phone needs it to share a zone, or why there isn't one.
    case account(user: String?, error: String?)
    /// A phone's inbox record that hasn't been answered.
    case inbox(zone: String, name: String, message: String)
    /// A zone that's gone (the phone unpaired, or left the share).
    case unlinked(zone: String)
    /// The sealed rendezvous record, or nil if `until` passed first.
    case rendezvous(name: String, sealed: Data?)
    case joined(zone: String?, owner: String?, error: String?)
    case log(message: String)
}

/// One message per line.
public enum RelayLine {
    public static func encode<T: Encodable>(_ value: T) -> Data {
        (try! JSONEncoder().encode(value)) + Data("\n".utf8)
    }

    public static func decode<T: Decodable>(_ type: T.Type, _ line: Data) -> T? {
        try? JSONDecoder().decode(type, from: line)
    }
}
