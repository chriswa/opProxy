import Foundation
import Security

/// 1Password as opProxy's 1Password helper presents it (`helper/main.go`): the 1Password
/// SDK's calls, with the SDK's own JSON types. The daemon builds everything `op` would print
/// from these.
public protocol OnePassword: AnyObject {
    func vaults() -> Result<[SDK.VaultOverview], SDK.Failure>
    func vault(_ vaultId: String) -> Result<SDK.VaultOverview, SDK.Failure>
    func items(vaultId: String, archived: Bool) -> Result<[SDK.ItemOverview], SDK.Failure>
    func item(vaultId: String, itemId: String) -> Result<SDK.Item, SDK.Failure>
    /// An `op://` reference's value, which 1Password works out itself (`?attribute=otp` too).
    func resolve(_ reference: String) -> Result<String, SDK.Failure>
    func file(vaultId: String, itemId: String, attributes: JSONValue) -> Result<Data, SDK.Failure>
    func create(_ params: SDK.ItemCreate) -> Result<SDK.Item, SDK.Failure>
    func put(_ item: SDK.Item) -> Result<SDK.Item, SDK.Failure>
    func delete(vaultId: String, itemId: String) -> Result<Void, SDK.Failure>
    func archive(vaultId: String, itemId: String) -> Result<Void, SDK.Failure>
}

public enum SDK {
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public enum Kind: String, Codable {
            /// 1Password ended the authorization (or never gave it): authorize again.
            case unauthorized
            /// 1Password's servers couldn't be reached; the authorization may still be good.
            case network
            case failed
        }

        public let kind: Kind
        public let message: String

        public init(_ kind: Kind, _ message: String) {
            self.kind = kind
            self.message = message
        }

        public var description: String { message }
    }

    public struct VaultOverview: Codable, Equatable {
        public let id: String
        public let title: String
        public let description: String?
        public let vaultType: String?
        public let activeItemCount: Int?
        public let contentVersion: Int?
        public let attributeVersion: Int?
        public let createdAt: String?
        public let updatedAt: String?

        public init(id: String, title: String, description: String? = nil, vaultType: String? = nil,
                    activeItemCount: Int? = nil, contentVersion: Int? = nil, attributeVersion: Int? = nil,
                    createdAt: String? = nil, updatedAt: String? = nil) {
            (self.id, self.title, self.description, self.vaultType) = (id, title, description, vaultType)
            (self.activeItemCount, self.contentVersion, self.attributeVersion) = (activeItemCount, contentVersion, attributeVersion)
            (self.createdAt, self.updatedAt) = (createdAt, updatedAt)
        }
    }

    public struct Website: Codable, Equatable {
        public var url: String
        public var label: String
        public var autofillBehavior: String

        public init(url: String, label: String = "website", autofillBehavior: String = "AnywhereOnWebsite") {
            (self.url, self.label, self.autofillBehavior) = (url, label, autofillBehavior)
        }
    }

    public struct ItemOverview: Codable, Equatable {
        public let id: String
        public let title: String
        public let category: String
        public let vaultId: String
        public let websites: [Website]?
        public let tags: [String]?
        public let createdAt: String?
        public let updatedAt: String?
        public let state: String?

        public init(id: String, title: String, category: String, vaultId: String, websites: [Website]? = nil,
                    tags: [String]? = nil, createdAt: String? = nil, updatedAt: String? = nil, state: String? = nil) {
            (self.id, self.title, self.category, self.vaultId) = (id, title, category, vaultId)
            (self.websites, self.tags, self.createdAt, self.updatedAt, self.state) = (websites, tags, createdAt, updatedAt, state)
        }
    }

    public struct Field: Codable, Equatable {
        public var id: String
        public var title: String
        public var sectionId: String?
        public var fieldType: String
        public var value: String
        /// The SDK's type-specific extras, kept as they came: an OTP field's current code.
        public var details: JSONValue?

        public init(id: String, title: String, sectionId: String? = nil, fieldType: String, value: String,
                    details: JSONValue? = nil) {
            (self.id, self.title, self.sectionId, self.fieldType, self.value, self.details) = (id, title, sectionId, fieldType, value, details)
        }

        /// The current one-time password, for a TOTP field.
        public var code: String? {
            guard case .object(let d) = details, case .object(let content)? = d["content"],
                  case .string(let code)? = content["code"] else { return nil }
            return code
        }
    }

    public struct Section: Codable, Equatable {
        public var id: String
        public var title: String

        public init(id: String, title: String) { (self.id, self.title) = (id, title) }
    }

    public struct Item: Codable, Equatable {
        public var id: String
        public var title: String
        public var category: String
        public var vaultId: String
        public var fields: [Field]
        public var sections: [Section]
        public var notes: String
        public var tags: [String]
        public var websites: [Website]
        public var version: Int
        /// Passed back untouched when the item is saved.
        public var files: JSONValue?
        public var document: JSONValue?
        public var createdAt: String
        public var updatedAt: String

        public init(id: String, title: String, category: String, vaultId: String, fields: [Field] = [],
                    sections: [Section] = [], notes: String = "", tags: [String] = [], websites: [Website] = [],
                    version: Int = 1, files: JSONValue? = nil, document: JSONValue? = nil,
                    createdAt: String = "", updatedAt: String = "") {
            (self.id, self.title, self.category, self.vaultId) = (id, title, category, vaultId)
            (self.fields, self.sections, self.notes, self.tags, self.websites) = (fields, sections, notes, tags, websites)
            (self.version, self.files, self.document, self.createdAt, self.updatedAt) = (version, files, document, createdAt, updatedAt)
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            category = try c.decode(String.self, forKey: .category)
            vaultId = try c.decode(String.self, forKey: .vaultId)
            fields = try c.decodeIfPresent([Field].self, forKey: .fields) ?? []
            sections = try c.decodeIfPresent([Section].self, forKey: .sections) ?? []
            notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
            tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
            websites = try c.decodeIfPresent([Website].self, forKey: .websites) ?? []
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
            files = try c.decodeIfPresent(JSONValue.self, forKey: .files)
            document = try c.decodeIfPresent(JSONValue.self, forKey: .document)
            createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
            updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        }

        public func section(_ id: String?) -> Section? { id.flatMap { id in sections.first { $0.id == id } } }
    }

    /// `ItemCreateParams`.
    public struct ItemCreate: Codable, Equatable {
        public var category: String
        public var vaultId: String
        public var title: String
        public var fields: [Field]
        public var sections: [Section]
        public var notes: String?
        public var tags: [String]
        public var websites: [Website]

        public init(category: String, vaultId: String, title: String, fields: [Field] = [], sections: [Section] = [],
                    notes: String? = nil, tags: [String] = [], websites: [Website] = []) {
            (self.category, self.vaultId, self.title) = (category, vaultId, title)
            (self.fields, self.sections, self.notes, self.tags, self.websites) = (fields, sections, notes, tags, websites)
        }
    }

    /// A random password: letters always, digits and symbols if asked. Generated here, from
    /// the system's secure random source, rather than by the SDK, whose generator runs
    /// WebAssembly that the helper's hardened runtime won't compile.
    public struct PasswordRecipe: Equatable {
        public var length: Int
        public var digits: Bool
        public var symbols: Bool

        public init(length: Int, digits: Bool, symbols: Bool) {
            (self.length, self.digits, self.symbols) = (length, digits, symbols)
        }

        static let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        static let digitSet = Array("0123456789")
        static let symbolSet = Array("!@#$%^&*-_=+.?")

        /// A new password: uniformly random over the allowed characters, with at least one
        /// digit and one symbol when those are asked for.
        public func generate() -> String {
            var alphabet = Self.letters
            if digits { alphabet += Self.digitSet }
            if symbols { alphabet += Self.symbolSet }
            while true {
                let password = (0..<length).map { _ in alphabet[Self.uniform(alphabet.count)] }
                if (!digits || length < 2 || password.contains(where: Self.digitSet.contains))
                    && (!symbols || length < 3 || password.contains(where: Self.symbolSet.contains)) {
                    return String(password)
                }
            }
        }

        /// A uniform index below `bound`, by rejection sampling over secure random bytes.
        static func uniform(_ bound: Int) -> Int {
            let limit = 256 - 256 % bound
            while true {
                var byte: UInt8 = 0
                precondition(SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess)
                if Int(byte) < limit { return Int(byte) % bound }
            }
        }
    }
}

/// Any JSON value, for the parts of the SDK's types opProxy passes through without reading.
public enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
