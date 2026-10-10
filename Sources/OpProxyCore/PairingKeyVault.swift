import FeedProtocol
import Foundation

/// Keeps each pairing's secret in 1Password: one Password item per paired phone, in the
/// account's default vault (Private, Personal or Employee). The daemon makes it when a phone
/// pairs, reads it back once 1Password has authorized its session at startup, and deletes
/// it on unpair. An agent running as you can't read it without going through 1Password's
/// authorization, and the daemon refuses to proxy it to anyone (`isPairingKey`).
///
/// 1Password generates the secret itself (`--generate-password`), so it never appears in a
/// command line, where other processes could see it, or in a file.
public struct PairingKeyVault {
    public static let titlePrefix = "opProxy pairing key"
    public static let tag = "opproxy-pairing"

    /// Runs `op` with these arguments in the daemon's authorized session.
    private let run: ([String]) -> ProxyResponse

    public init(run: @escaping ([String]) -> ProxyResponse) {
        self.run = run
    }

    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    /// Whether a proxied request names a pairing key. Renaming an item is a write, which
    /// needs 1Password's own authorization, so the title is a safe thing to go by.
    public static func isPairingKey(title: String) -> Bool { title.hasPrefix(titlePrefix) }

    /// Makes the item for a newly paired phone and returns its ID with the secret.
    public func create(phoneName: String, macName: String) throws -> (itemId: String, secret: Data) {
        let response = run(["item", "create", "--category", "password", "--title", "\(Self.titlePrefix): \(phoneName) · \(macName)",
                            "--tags", Self.tag, "--generate-password=letters,digits,64", "--format", "json", "--reveal"])
        let item = try parse(response, doing: "create the pairing key")
        return (item.id, try secret(of: item))
    }

    /// Reads a pairing's secret back. Only an item this vault made counts: one with the
    /// pairing title and tag. Nothing checks it's the very key paired: planting another would
    /// take writing to 1Password, which already reveals more than this key protects.
    public func load(itemId: String) throws -> PairingKey {
        let item = try parse(run(["item", "get", itemId, "--format", "json", "--reveal"]), doing: "read the pairing key")
        guard Self.isPairingKey(title: item.title), item.tags?.contains(Self.tag) == true, item.category == "PASSWORD" else {
            throw Failure(description: "1Password item \(itemId) isn't an opProxy pairing key")
        }
        return PairingKey(secret: try secret(of: item))
    }

    /// Deletes a pairing's item, for unpairing. An item that's already gone counts as deleted.
    public func delete(itemId: String) throws {
        let response = run(["item", "delete", itemId])
        let stderr = String(decoding: response.stderr, as: UTF8.self)
        guard response.exitCode == 0 || stderr.contains("isn't an item") else {
            throw Failure(description: "could not delete the pairing key: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    struct Item: Decodable {
        struct Field: Decodable {
            let id: String?
            let purpose: String?
            let value: String?
        }
        let id: String
        let title: String
        let category: String
        let tags: [String]?
        let fields: [Field]?
    }

    private func parse(_ response: ProxyResponse, doing what: String) throws -> Item {
        guard response.exitCode == 0 else {
            let stderr = String(decoding: response.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(description: "could not \(what): \(stderr.isEmpty ? "op exited \(response.exitCode)" : stderr)")
        }
        guard let item = try? JSONDecoder().decode(Item.self, from: response.stdout) else {
            throw Failure(description: "could not \(what): op's output wasn't an item")
        }
        return item
    }

    private func secret(of item: Item) throws -> Data {
        let field = item.fields?.first { $0.purpose == "PASSWORD" } ?? item.fields?.first { $0.id == "password" }
        guard let value = field?.value, value.count >= 32 else {
            throw Failure(description: "1Password item \(item.id) has no generated password")
        }
        return Data(value.utf8)
    }
}
