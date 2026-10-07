import CryptoKit
import Foundation

/// How the approval feed is laid out in CloudKit. Each paired iPhone owns a zone in its
/// private database and shares it with the Mac, so the phone can subscribe to new requests
/// alone (a query subscription, which only a zone's owner can make). Every feed field is an
/// encrypted value, end to end between the user's devices.
public enum CloudFeed {
    public static let container = "iCloud.com.chriswa.opproxy"
    public static let zoneName = "approvalFeed"

    /// Written by the Mac. Record name: the item's ID.
    public enum Item {
        public static let type = "FeedItem"
        /// The item as APPROVAL_FEED.md writes it, as a JSON string.
        public static let item = "item"
        /// Set once the item is no longer pending: why ("Approved on the Mac").
        public static let note = "note"
    }

    /// Written by the Mac. Record names: `hello` and `status`.
    public enum State {
        public static let type = "FeedState"
        public static let hello = "hello"
        public static let status = "status"
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
    /// carries a one-time code; the phone leaves its zone's share URL in the public database,
    /// sealed with a key derived from the code, under a name derived from it too. Only someone
    /// who saw the QR code can find or open it.
    public enum Rendezvous {
        public static let type = "PairingRendezvous"
        public static let sealed = "sealed"
        public static let scheme = "opproxy-pair"

        public static func newCode() -> Data {
            Data(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) })
        }

        /// What the QR code holds: `opproxy-pair:1:<base64url code>`.
        public static func qrPayload(code: Data) -> String { "\(scheme):1:\(base64url(code))" }

        public static func code(fromQR payload: String) -> Data? {
            let parts = payload.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == scheme, parts[1] == "1" else { return nil }
            return unbase64url(String(parts[2])).flatMap { $0.count == 16 ? $0 : nil }
        }

        public static func recordName(code: Data) -> String {
            hex(Data(HMAC<SHA256>.authenticationCode(for: Data("record".utf8), using: SymmetricKey(data: code))))
        }

        public static func seal(_ shareURL: URL, code: Data) throws -> Data {
            try ChaChaPoly.seal(Data(shareURL.absoluteString.utf8), using: key(code)).combined
        }

        public static func open(_ sealed: Data, code: Data) -> URL? {
            guard let box = try? ChaChaPoly.SealedBox(combined: sealed),
                  let plain = try? ChaChaPoly.open(box, using: key(code)) else { return nil }
            return URL(string: String(decoding: plain, as: UTF8.self))
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
