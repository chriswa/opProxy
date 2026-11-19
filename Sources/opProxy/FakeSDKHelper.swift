#if OPPROXY_TESTING
import Foundation
import OpProxyCore

/// `opProxy fake-sdk-helper <fixture.json>`, debug builds only: stands in for the 1Password
/// helper (`helper/main.go`) in the integration tests, speaking the same protocol over a
/// fixture of vaults and items. Writes are saved back to the fixture.
///
/// Authorization is a file beside the fixture, as a real prompt would leave it: `authorize`
/// creates `authorized` (or fails while `refuse-auth` exists), and every other call fails as
/// unauthorized once `authorized` is gone.
enum FakeSDKHelper {
    struct Fixture: Codable {
        var vaults: [SDK.VaultOverview]
        var items: [SDK.Item]
        var archived: [String]?
    }

    static func run(_ fixture: URL) -> Never {
        let dir = fixture.deletingLastPathComponent()
        let authorizedFile = dir.appendingPathComponent("authorized")
        var authorized = false
        let reader = LineReader(fd: STDIN_FILENO)
        while let line = reader.next() {
            guard case .object(let request)? = try? JSONDecoder().decode(JSONValue.self, from: line),
                  case .number(let id)? = request["id"], case .string(let method)? = request["method"] else { continue }
            var params: [String: JSONValue] = [:]
            if case .object(let p)? = request["params"] { params = p }
            var reply: [String: JSONValue] = ["id": .number(id)]
            func fail(_ kind: String, _ message: String) {
                reply["error"] = .object(["kind": .string(kind), "message": .string(message)])
            }
            if method == "authorize" {
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent("refuse-auth").path) {
                    fail("failed", "authorization dismissed")
                } else {
                    FileManager.default.createFile(atPath: authorizedFile.path, contents: nil)
                    authorized = true
                    reply["result"] = .object(["vaults": .number(1)])
                }
            } else if !authorized || !FileManager.default.fileExists(atPath: authorizedFile.path) {
                fail("unauthorized", "invalid client id")
            } else {
                do {
                    reply["result"] = try handle(method, params, fixture: fixture)
                } catch let failure as SDK.Failure {
                    fail(failure.kind.rawValue, failure.message)
                } catch {
                    fail("failed", "\(error)")
                }
            }
            if let body = try? JSONEncoder().encode(JSONValue.object(reply)) {
                _ = UnixSocket.writeAll(STDOUT_FILENO, body + Data("\n".utf8))
            }
        }
        exit(0)
    }

    private static func handle(_ method: String, _ params: [String: JSONValue], fixture url: URL) throws -> JSONValue {
        var fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        func string(_ key: String) -> String {
            if case .string(let s)? = params[key] { return s }
            return ""
        }
        func json<T: Encodable>(_ value: T) throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        }
        func decoded<T: Decodable>(_ key: String) throws -> T {
            try JSONDecoder().decode(T.self, from: JSONEncoder().encode(params[key] ?? .null))
        }
        func save() throws { try JSONEncoder().encode(fixture).write(to: url) }
        let archived = Set(fixture.archived ?? [])
        func find(_ vaultId: String, _ itemId: String) throws -> Int {
            guard let i = fixture.items.firstIndex(where: { $0.id == itemId && $0.vaultId == vaultId }) else {
                throw SDK.Failure(.failed, "item \(itemId) not found")
            }
            return i
        }
        switch method {
        case "vaults":
            return try json(fixture.vaults)
        case "vault":
            guard let v = fixture.vaults.first(where: { $0.id == string("vaultId") }) else { throw SDK.Failure(.failed, "no vault") }
            return try json(v)
        case "items":
            let withArchived = params["archived"] == .bool(true)
            return try json(fixture.items.filter { $0.vaultId == string("vaultId") && (withArchived || !archived.contains($0.id)) }.map {
                SDK.ItemOverview(id: $0.id, title: $0.title, category: $0.category, vaultId: $0.vaultId, websites: $0.websites,
                                 tags: $0.tags, createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                                 state: archived.contains($0.id) ? "archived" : "active")
            })
        case "item":
            return try json(fixture.items[find(string("vaultId"), string("itemId"))])
        case "resolve":
            let ref = string("reference")
            guard ref.hasPrefix("op://") else { throw SDK.Failure(.failed, "not a secret reference") }
            let (path, query) = ref.dropFirst(5).split(separator: "?", maxSplits: 1).map(String.init).splitFirst
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { throw SDK.Failure(.failed, "bad reference") }
            let item = fixture.items[try find(parts[0], parts[1])]
            let fieldName = parts.last!
            let sectionName = parts.count == 4 ? parts[2] : nil
            if sectionName == nil, fieldName == "notesPlain" { return .string(item.notes) }
            guard let field = item.fields.first(where: { f in
                (f.title.caseInsensitiveCompare(fieldName) == .orderedSame || f.id == fieldName)
                    && (sectionName.map { s in item.section(f.sectionId).map { $0.title == s || $0.id == s } ?? false } ?? true)
            }) else { throw SDK.Failure(.failed, "no field \(fieldName)") }
            return .string(query == "attribute=otp" ? (field.code ?? "") : field.value)
        case "file":
            return .string(Data("document \(string("itemId"))\n".utf8).base64EncodedString())
        case "create":
            let create: SDK.ItemCreate = try decoded("create")
            let now = ISO8601DateFormatter().string(from: Date())
            let item = SDK.Item(id: "new\(fixture.items.count)", title: create.title, category: create.category,
                                vaultId: create.vaultId, fields: create.fields, sections: create.sections,
                                notes: create.notes ?? "", tags: create.tags, websites: create.websites, version: 1,
                                createdAt: now, updatedAt: now)
            fixture.items.append(item)
            try save()
            return try json(item)
        case "put":
            var item: SDK.Item = try decoded("item")
            item.version += 1
            fixture.items[try find(item.vaultId, item.id)] = item
            try save()
            return try json(item)
        case "delete":
            fixture.items.remove(at: try find(string("vaultId"), string("itemId")))
            try save()
            return .bool(true)
        case "archive":
            _ = try find(string("vaultId"), string("itemId"))
            fixture.archived = (fixture.archived ?? []) + [string("itemId")]
            try save()
            return .bool(true)
        default:
            throw SDK.Failure(.failed, "unknown method \(method)")
        }
    }
}

private extension Array where Element == String {
    var splitFirst: (String, String?) { (self[0], count > 1 ? self[1] : nil) }
}
#endif
