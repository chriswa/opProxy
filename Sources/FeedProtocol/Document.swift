import Foundation

/// A pending request as the feed publishes it (APPROVAL_FEED.md, "Item").
public struct FeedItem: Decodable, Equatable, Identifiable {
    public let id: String
    public let revision: Int
    public let createdAt: Double
    public let expiresAt: Double?
    public let challenge: String
    /// The exact string the Mac sent: what a reply's `documentSha256` covers.
    public let document: String

    public var parsed: FeedDocument? { try? JSONDecoder().decode(FeedDocument.self, from: Data(document.utf8)) }
    public var documentSha256: String { sha256Hex(Data(document.utf8)) }
    public var created: Date { Date(timeIntervalSince1970: createdAt / 1000) }
    public var expires: Date? { expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) } }

    public static func parse(_ json: String) -> FeedItem? { try? JSONDecoder().decode(FeedItem.self, from: Data(json.utf8)) }
}

/// What a request shows, in the feed's small vocabulary (APPROVAL_FEED.md, "Document").
public struct FeedDocument: Decodable, Equatable {
    public struct Row: Decodable, Equatable, Hashable {
        public let label: String
        public let value: String
        public let mono: Bool?
    }

    public struct Section: Decodable, Equatable, Hashable {
        public let kind: String?
        public let label: String?
        public let rows: [Row]?
        public let text: String?
        public let mono: Bool?
    }

    public struct Option: Decodable, Equatable, Hashable {
        public let id: String
        public let label: String
        public let hint: String?
    }

    public struct Picker: Decodable, Equatable, Hashable {
        public let id: String
        public let label: String?
        public let `default`: String?
        public let options: [Option]
    }

    public struct Action: Decodable, Equatable, Hashable {
        public let id: String
        public let label: String
        /// "approve", "deny", or anything else.
        public let role: String?
    }

    public let tone: String?
    public let kicker: String?
    public let title: String
    public let subtitle: String?
    public let sections: [Section]?
    public let notice: String?
    public let pickers: [Picker]?
    public let actions: [Action]
    public let confirm: String
}

/// The provider's status (APPROVAL_FEED.md, "Provider status").
public struct FeedProviderStatus: Decodable, Equatable {
    public let ok: Bool
    public let label: String?
    public let since: Double
    public let until: Double?
    public let title: String?
    public let detail: String?

    public var untilDate: Date? { until.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

/// Builds and signs replies. `sign` gets the statement's UTF-8 bytes and returns a DER
/// ECDSA P-256 signature.
public enum FeedReply {
    public static func message(item: FeedItem, action: String, picks: [String: String], keyId: String,
                               sign: (Data) throws -> Data) throws -> [String: Any] {
        let statement = ApprovalStatement(id: item.id, revision: item.revision, challenge: item.challenge,
                                          documentSha256: item.documentSha256, action: action, picks: picks, keyId: keyId,
                                          signedAt: (Date().timeIntervalSince1970 * 1000).rounded())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = String(decoding: try encoder.encode(statement), as: UTF8.self)
        let signature = try sign(Data(text.utf8))
        return ["type": "reply", "id": item.id, "keyId": keyId, "statement": text, "signature": signature.base64EncodedString()]
    }

    public static func pair(publicKey: Data, name: String) -> [String: Any] {
        ["type": "pair", "publicKey": publicKey.base64EncodedString(), "name": name]
    }
}
