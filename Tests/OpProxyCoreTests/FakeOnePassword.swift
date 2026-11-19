import Foundation
@testable import OpProxyCore

/// 1Password in memory, for tests: vaults and items, with every call recorded.
final class FakeOnePassword: OnePassword {
    var vaultList: [SDK.VaultOverview]
    var stored: [SDK.Item]
    var archived: Set<String> = []
    var calls: [String] = []
    /// Every call fails with this, when set.
    var failure: SDK.Failure?
    var otp = "123456"

    init(vaults: [SDK.VaultOverview] = [], items: [SDK.Item] = []) {
        vaultList = vaults
        stored = items
    }

    private func answer<T>(_ call: String, _ body: () throws -> T) -> Result<T, SDK.Failure> {
        calls.append(call)
        if let failure { return .failure(failure) }
        do { return .success(try body()) } catch let f as SDK.Failure { return .failure(f) } catch {
            return .failure(SDK.Failure(.failed, "\(error)"))
        }
    }

    private func index(_ vaultId: String, _ itemId: String) throws -> Int {
        guard let i = stored.firstIndex(where: { $0.id == itemId && $0.vaultId == vaultId }) else {
            throw SDK.Failure(.failed, "item not found")
        }
        return i
    }

    func vaults() -> Result<[SDK.VaultOverview], SDK.Failure> { answer("vaults") { vaultList } }

    func vault(_ vaultId: String) -> Result<SDK.VaultOverview, SDK.Failure> {
        answer("vault \(vaultId)") {
            guard let v = vaultList.first(where: { $0.id == vaultId }) else { throw SDK.Failure(.failed, "no vault") }
            return v
        }
    }

    func items(vaultId: String, archived withArchived: Bool) -> Result<[SDK.ItemOverview], SDK.Failure> {
        answer("items \(vaultId)") {
            stored.filter { $0.vaultId == vaultId && (withArchived || !archived.contains($0.id)) }.map {
                SDK.ItemOverview(id: $0.id, title: $0.title, category: $0.category, vaultId: $0.vaultId, websites: $0.websites,
                                 tags: $0.tags, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
            }
        }
    }

    func item(vaultId: String, itemId: String) -> Result<SDK.Item, SDK.Failure> {
        answer("item \(itemId)") { stored[try index(vaultId, itemId)] }
    }

    func resolve(_ reference: String) -> Result<String, SDK.Failure> {
        answer("resolve \(reference)") {
            let parts = reference.dropFirst("op://".count).split(separator: "?")[0].split(separator: "/").map(String.init)
            let item = stored[try index(parts[0], parts[1])]
            if reference.hasSuffix("?attribute=otp") { return otp }
            guard let field = item.fields.first(where: { $0.title == parts.last! || $0.id == parts.last! }) else {
                throw SDK.Failure(.failed, "no such field")
            }
            return field.value
        }
    }

    func file(vaultId: String, itemId: String, attributes: JSONValue) -> Result<Data, SDK.Failure> {
        answer("file \(itemId)") { Data("contents of \(itemId)".utf8) }
    }

    func create(_ params: SDK.ItemCreate) -> Result<SDK.Item, SDK.Failure> {
        answer("create") {
            let item = SDK.Item(id: "created\(stored.count)", title: params.title, category: params.category,
                                vaultId: params.vaultId, fields: params.fields, sections: params.sections,
                                notes: params.notes ?? "", tags: params.tags, websites: params.websites, version: 1,
                                createdAt: "2026-11-18T10:00:00Z", updatedAt: "2026-11-18T10:00:00Z")
            stored.append(item)
            return item
        }
    }

    func put(_ item: SDK.Item) -> Result<SDK.Item, SDK.Failure> {
        answer("put \(item.id)") {
            var saved = item
            saved.version += 1
            stored[try index(item.vaultId, item.id)] = saved
            return saved
        }
    }

    func delete(vaultId: String, itemId: String) -> Result<Void, SDK.Failure> {
        answer("delete \(itemId)") { stored.remove(at: try index(vaultId, itemId)) }
    }

    func archive(vaultId: String, itemId: String) -> Result<Void, SDK.Failure> {
        answer("archive \(itemId)") { _ = try index(vaultId, itemId); archived.insert(itemId) }
    }
}
