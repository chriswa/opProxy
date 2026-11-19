import FeedProtocol
import Foundation

/// Keeps each pairing's secret in 1Password: one Password item per paired phone, in the
/// account's own vault (Private, Personal or Employee). The daemon makes it when a phone
/// pairs, reads it back once 1Password has authorized it at startup, and deletes it on
/// unpair. An agent running as you can't read it without going through 1Password's
/// authorization, and the daemon refuses to hand it to anyone (`isPairingKey`).
///
/// The secret is generated here and goes to 1Password over the helper's pipe, so it never
/// appears in a command line or a file.
public struct PairingKeyVault {
    public static let titlePrefix = "opProxy pairing key"
    public static let tag = "opproxy-pairing"

    /// The daemon's authorized 1Password session; getting it may ask 1Password, saying why
    /// (true: to delete a key).
    private let client: (_ deleting: Bool) -> Result<OnePassword, SDK.Failure>

    public init(client: @escaping (_ deleting: Bool) -> Result<OnePassword, SDK.Failure>) {
        self.client = client
    }

    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    /// Whether a request names a pairing key. Renaming an item is a write, which opProxy also
    /// refuses for these, so the title is a safe thing to go by.
    public static func isPairingKey(title: String) -> Bool { title.hasPrefix(titlePrefix) }

    /// Makes the item for a newly paired phone and returns its ID with the secret.
    public func create(phoneName: String, macName: String) throws -> (itemId: String, secret: Data) {
        let op = try session(doing: "create the pairing key")
        let vault = try get(op.vaults(), doing: "create the pairing key").first { $0.vaultType == "personal" }
        guard let vault else { throw Failure(description: "could not create the pairing key: this account has no Private vault") }
        let password = SDK.PasswordRecipe(length: 64, digits: true, symbols: false).generate()
        let item = try get(op.create(SDK.ItemCreate(
            category: "Password", vaultId: vault.id, title: "\(Self.titlePrefix): \(phoneName) · \(macName)",
            fields: [SDK.Field(id: "password", title: "password", fieldType: "Concealed", value: password)],
            tags: [Self.tag])), doing: "create the pairing key")
        return (item.id, try secret(of: item))
    }

    /// Reads a pairing's secret back. Only an item this vault made counts: one with the
    /// pairing title and tag. Nothing checks it's the very key paired: planting another would
    /// take writing to 1Password, which already reveals more than this key protects.
    public func load(itemId: String) throws -> PairingKey {
        let op = try session(doing: "read the pairing key")
        guard let vaultId = try find(itemId, in: op, doing: "read the pairing key") else {
            throw Failure(description: "1Password item \(itemId) is gone")
        }
        let item = try get(op.item(vaultId: vaultId, itemId: itemId), doing: "read the pairing key")
        guard Self.isPairingKey(title: item.title), item.tags.contains(Self.tag), item.category == "Password" else {
            throw Failure(description: "1Password item \(itemId) isn't an opProxy pairing key")
        }
        return PairingKey(secret: try secret(of: item))
    }

    /// Deletes a pairing's item, for unpairing. An item that's already gone counts as deleted.
    public func delete(itemId: String) throws {
        let op = try get(client(true), doing: "delete the pairing key")
        guard let vaultId = try find(itemId, in: op, doing: "delete the pairing key") else { return }
        _ = try get(op.delete(vaultId: vaultId, itemId: itemId), doing: "delete the pairing key")
    }

    private func session(doing what: String) throws -> OnePassword {
        try get(client(false), doing: what)
    }

    /// The vault holding `itemId`, archived or not.
    private func find(_ itemId: String, in op: OnePassword, doing what: String) throws -> String? {
        for vault in try get(op.vaults(), doing: what) {
            if try get(op.items(vaultId: vault.id, archived: true), doing: what).contains(where: { $0.id == itemId }) {
                return vault.id
            }
        }
        return nil
    }

    private func get<T>(_ result: Result<T, SDK.Failure>, doing what: String) throws -> T {
        try result.mapError { Failure(description: "could not \(what): \($0.message)") }.get()
    }

    private func secret(of item: SDK.Item) throws -> Data {
        let field = item.fields.first { $0.id == "password" } ?? item.fields.first { $0.fieldType == "Concealed" }
        guard let value = field?.value, value.count >= 32 else {
            throw Failure(description: "1Password item \(item.id) has no generated password")
        }
        return Data(value.utf8)
    }
}
