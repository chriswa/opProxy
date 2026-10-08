import CryptoKit
import Foundation

/// How the approval feed is laid out in CloudKit. An iPhone owns one zone in its private
/// database per Mac it's paired with, shared with that Mac's iCloud user alone, so no Mac sees
/// another's requests and the phone can subscribe to new requests by itself (a query
/// subscription, which only a zone's owner can make). Every feed field is an encrypted value,
/// end to end between the user's devices.
public enum CloudFeed {
    public static let container = "iCloud.com.chriswa.opproxy"
    public static let zonePrefix = "feed-"
    /// The single zone of phones paired before a phone could serve several Macs.
    public static let legacyZoneName = "approvalFeed"

    /// The zone for the Mac with this ID (`MacIdentity` on the Mac).
    public static func zoneName(macID: String) -> String { zonePrefix + macID }

    /// Written by the Mac. Record name: the item's ID.
    public enum Item {
        public static let type = "FeedItem"
        /// The item as APPROVAL_FEED.md writes it, as a JSON string.
        public static let item = "item"
        /// Set once the item is no longer pending: why ("Allowed on the Mac").
        public static let note = "note"
    }

    /// Written by the Mac. Record names: `hello` (with the Mac's name), `status`, and
    /// `presence`, which the Mac refreshes every `presenceInterval` while it has pending
    /// requests, so a phone can tell a Mac that's asleep from one that's slow.
    public enum State {
        public static let type = "FeedState"
        public static let hello = "hello"
        public static let status = "status"
        public static let presence = "presence"
        public static let presenceInterval: TimeInterval = 30
        /// After this long without presence, a phone treats the Mac's requests as stuck.
        public static let presenceTimeout: TimeInterval = 90
        /// The APPROVAL_FEED.md message, as a JSON string.
        public static let message = "message"
    }

    /// Written by the phone, answered by the Mac. Record name: random.
    public enum Inbox {
        public static let type = "FeedInbox"
        /// A `reply` or `pair` message, as a JSON string.
        public static let message = "message"
        /// The Mac's `reply-result` or `pair-result`, as a JSON string.
        public static let response = "response"
    }

    /// The first step of pairing, before the Mac can read the phone's zone. The Mac's QR code
    /// carries a one-time code and the Mac's iCloud user (its user record name in this
    /// container). The phone invites exactly that user to its zone's share, which is never
    /// open to anyone holding the link, then leaves an `Invitation` in the public database,
    /// sealed with a key derived from the code, under a name derived from it too.
    public enum Rendezvous {
        public static let type = "PairingRendezvous"
        public static let sealed = "sealed"
        public static let scheme = "opproxy-pair"

        /// What the phone tells the Mac: the share it was invited to, or, when both are on
        /// the same Apple ID, the zone in their shared private database.
        public enum Invitation: Codable, Equatable {
            case share(URL)
            case ownZone(String)
        }

        public static func newCode() -> Data {
            Data(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) })
        }

        /// What the QR code holds: `opproxy-pair:3:<base64url code>:<Mac's user record name>:<Mac's ID>`.
        public static func qrPayload(code: Data, macUser: String, macID: String) -> String {
            "\(scheme):3:\(base64url(code)):\(macUser):\(macID)"
        }

        public static func parse(qr payload: String) -> (code: Data, macUser: String, macID: String)? {
            let parts = payload.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 5, parts[0] == scheme, parts[1] == "3", !parts[3].isEmpty,
                  parts[4].range(of: "^[a-z0-9-]{8,64}$", options: .regularExpression) != nil,
                  let code = unbase64url(parts[2]), code.count == 16 else { return nil }
            return (code, parts[3], parts[4])
        }

        public static func recordName(code: Data) -> String {
            hex(Data(HMAC<SHA256>.authenticationCode(for: Data("record".utf8), using: SymmetricKey(data: code))))
        }

        public static func seal(_ invitation: Invitation, code: Data) throws -> Data {
            try ChaChaPoly.seal(JSONEncoder().encode(invitation), using: key(code)).combined
        }

        public static func open(_ sealed: Data, code: Data) -> Invitation? {
            guard let box = try? ChaChaPoly.SealedBox(combined: sealed),
                  let plain = try? ChaChaPoly.open(box, using: key(code)) else { return nil }
            return try? JSONDecoder().decode(Invitation.self, from: plain)
        }

        private static func key(_ code: Data) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: code), info: Data("opProxy rendezvous".utf8),
                                   outputByteCount: 32)
        }
    }
}

public func base64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

public func unbase64url(_ text: String) -> Data? {
    var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }
    return Data(base64Encoded: s)
}
