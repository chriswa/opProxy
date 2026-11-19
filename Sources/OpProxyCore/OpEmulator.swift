import Foundation

/// The 1Password account opProxy's session is for, as `op account list` describes it.
public struct OnePasswordAccount: Codable, Equatable {
    public let url: String
    public let email: String
    public let userUUID: String
    public let accountUUID: String

    enum CodingKeys: String, CodingKey {
        case url, email
        case userUUID = "user_uuid"
        case accountUUID = "account_uuid"
    }

    public init(url: String, email: String, userUUID: String, accountUUID: String) {
        (self.url, self.email, self.userUUID, self.accountUUID) = (url, email, userUUID, accountUUID)
    }

    /// Whether `--account` or `OP_ACCOUNT` names this account: by its sign-in address (with
    /// or without `https://` or the domain), its email, or either ID, in any case.
    public func matches(_ name: String) -> Bool {
        let wanted = name.lowercased().replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let host = url.lowercased().replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return [host, String(host.prefix { $0 != "." }), email.lowercased(), userUUID.lowercased(), accountUUID.lowercased()]
            .contains(wanted)
    }
}

/// Answers the `op` commands opProxy handles, as `op` would, from the 1Password SDK. Item
/// requests arrive already resolved to one item by ID and, if they need it, approved.
public struct OpEmulator {
    let client: OnePassword
    let account: OnePasswordAccount
    let now: () -> Date

    public init(client: OnePassword, account: OnePasswordAccount, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.account = account
        self.now = now
    }

    /// Output options from the command's flags and the caller's `OP_*` variables.
    struct Style {
        let json: Bool
        let iso: Bool
        let includeArchive: Bool

        init(flags: [String: String], env: [String: String]) {
            json = (flags["--format"] ?? env["OP_FORMAT"])?.lowercased() == "json"
            iso = flags["--iso-timestamps"] != nil || Self.on(env["OP_ISO_TIMESTAMPS"])
            includeArchive = flags["--include-archive"] != nil || Self.on(env["OP_INCLUDE_ARCHIVE"])
        }

        /// An `OP_*` switch: set to anything but empty, 0 or false.
        static func on(_ v: String?) -> Bool { v.map { !["", "0", "false"].contains($0.lowercased()) } ?? false }
    }

    /// Whether a read also looks among archived items, as its flags and `OP_INCLUDE_ARCHIVE` say.
    public static func includesArchive(_ request: ItemRequest, env: [String: String]) -> Bool {
        Style(flags: request.flags, env: env).includeArchive
    }

    // MARK: Listings

    public func metadata(_ request: MetadataRequest, env: [String: String]) -> ProxyResponse {
        let style = Style(flags: request.flags, env: env)
        switch request.path {
        case "whoami":
            if style.json {
                return ok(OpOutput.json(OpOutput.ordered([("url", whoamiURL), ("email", account.email),
                                                           ("user_uuid", account.userUUID), ("account_uuid", account.accountUUID)])))
            }
            return ok(OpOutput.columns([["URL:", whoamiURL], ["Email:", account.email], ["User ID:", account.userUUID]]))
        case "vault list":
            return attempt {
                let vaults = try client.vaults().get().sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                if style.json { return OpOutput.json(vaults.map { OpOutput.ordered(OpOutput.vaultJSON($0, detailed: false)) }) }
                return OpOutput.columns([["ID", "NAME"]] + vaults.map { [$0.id, $0.title] })
            }
        case "vault get":
            return attempt {
                let vault = try vaultNamed(request.target!)
                return style.json ? OpOutput.json(OpOutput.ordered(OpOutput.vaultJSON(vault, detailed: true)))
                    : OpOutput.vaultHuman(vault, iso: style.iso, now: now())
            }
        default:
            return attempt { try itemList(request, style: style) }
        }
    }

    private var whoamiURL: String {
        "https://" + account.url.replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
    }

    private func itemList(_ request: MetadataRequest, style: Style) throws -> String {
        var vaults = try client.vaults().get()
        if let name = request.flags["--vault"] { vaults = [try vaultNamed(name, in: vaults)] }
        var categories: Set<String>?
        if let names = request.flags["--categories"] {
            categories = Set(try names.split(separator: ",").map { name -> String in
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                guard let sdk = OpOutput.sdkCategory(named: trimmed) else { throw OpError("\"\(trimmed)\" isn't a category") }
                return sdk
            })
        }
        let tags = request.flags["--tags"].map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
        var rows: [(SDK.ItemOverview, String)] = []
        for vault in vaults {
            for item in try client.items(vaultId: vault.id, archived: style.includeArchive).get() {
                if let categories, !categories.contains(item.category) { continue }
                if let tags, tags.isDisjoint(with: item.tags ?? []) { continue }
                rows.append((item, vault.title))
            }
        }
        rows.sort { ($0.0.updatedAt ?? "") > ($1.0.updatedAt ?? "") }
        if style.json { return OpOutput.json(rows.map { OpOutput.ordered(OpOutput.overviewJSON($0.0, vaultName: $0.1)) }) }
        let n = now()
        return OpOutput.columns([["ID", "TITLE", "VAULT", "EDITED"]] + rows.map { item, vault in
            [item.id, item.title, vault, item.updatedAt.map { OpOutput.when($0, iso: style.iso, now: n) } ?? ""]
        })
    }

    /// Every item in the account, for working out which one a request means. Listings carry no
    /// secret values.
    public func catalog(includeArchive: Bool) -> Result<ItemCatalog, SDK.Failure> {
        Result {
            var all: [ItemIdentity] = []
            for vault in try client.vaults().get() {
                all += try client.items(vaultId: vault.id, archived: includeArchive).get().map {
                    ItemIdentity(itemId: $0.id, vaultId: vault.id, title: $0.title, vaultName: vault.title)
                }
            }
            return ItemCatalog(all)
        }.mapError { $0 as? SDK.Failure ?? SDK.Failure(.failed, "\($0)") }
    }

    /// The vault a name or ID means, in any case.
    func vaultNamed(_ name: String, in vaults: [SDK.VaultOverview]? = nil) throws -> SDK.VaultOverview {
        let all = try vaults ?? client.vaults().get()
        if let v = all.first(where: { $0.id == name }) ?? all.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
            return v
        }
        throw OpError("\"\(name)\" isn't a vault in this account. Specify the vault with its ID or name.")
    }

    /// Where `op item create` puts an item when no vault is named: the account's own vault
    /// (Private, Personal or Employee).
    public func vaultForCreate(_ name: String?) -> Result<SDK.VaultOverview, SDK.Failure> {
        Result {
            let all = try client.vaults().get()
            if let name { return try vaultNamed(name, in: all) }
            guard let personal = all.first(where: { $0.vaultType == "personal" }) else {
                throw OpError("this account has no Private vault: name one with --vault")
            }
            return personal
        }.mapError { $0 as? SDK.Failure ?? SDK.Failure(.failed, "\($0)") }
    }

    // MARK: Secrets

    public func read(_ request: ItemRequest, target: ItemIdentity, env: [String: String]) -> ProxyResponse {
        let style = Style(flags: request.flags, env: env)
        switch request.kind {
        case .read(let ref):
            return attempt {
                let value = try client.resolve(ref.pinned(vaultId: target.vaultId, itemId: target.itemId)).get()
                let newline = request.flags["-n"] == nil && request.flags["--no-newline"] == nil
                return value + (newline ? "\n" : "")
            }
        case .documentGet:
            return attemptData {
                let item = try client.item(vaultId: target.vaultId, itemId: target.itemId).get()
                guard let document = item.document else { throw OpError("\"\(target.title)\" isn't a document") }
                return try client.file(vaultId: target.vaultId, itemId: target.itemId, attributes: document).get()
            }
        case .itemGet:
            return attempt {
                let item = try client.item(vaultId: target.vaultId, itemId: target.itemId).get()
                return try itemGet(item, request: request, vaultName: target.vaultName, style: style)
            }
        }
    }

    private func itemGet(_ item: SDK.Item, request: ItemRequest, vaultName: String, style: Style) throws -> String {
        let reveal = request.flags["--reveal"] != nil
        if request.flags["--otp"] != nil {
            guard let code = item.fields.first(where: { $0.fieldType == "Totp" })?.code else {
                throw OpError("\"\(item.title)\" has no one-time password field")
            }
            return code + "\n"
        }
        guard let spec = request.flags["--fields"] else { return render(item, vaultName: vaultName, reveal: reveal, style: style) }
        let fields = OpOutput.fields(of: item, vaultName: vaultName)
        var chosen: [OpOutput.OpField] = []
        for part in spec.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            let matches: [OpOutput.OpField]
            switch (kv.count == 2 ? kv[0].lowercased() : "", kv.last!) {
            case ("type", let type): matches = fields.filter { $0.type.caseInsensitiveCompare(type) == .orderedSame }
            case (_, let name):
                matches = fields.filter {
                    $0.label.caseInsensitiveCompare(name) == .orderedSame || $0.id == name
                        || ($0.section.map { "\($0.title).".lowercased() } ?? "") + $0.label.lowercased() == name.lowercased()
                }
            }
            guard !matches.isEmpty else { throw OpError("\"\(part)\" isn't a field in the \"\(item.title)\" item") }
            chosen += matches.filter { m in !chosen.contains { $0.id == m.id && $0.section?.id == m.section?.id } }
        }
        if style.json {
            let objects = chosen.map { OpOutput.ordered($0.json) }
            return OpOutput.json(objects.count == 1 ? objects[0] : objects)
        }
        return chosen.map { $0.concealed && !reveal ? OpOutput.concealedHint(item.id) : $0.value }.joined(separator: ",") + "\n"
    }

    /// `concealing`: never show concealed values, even in JSON (`op` does), for a write's
    /// output: approving a change doesn't approve reading the item's secrets.
    private func render(_ item: SDK.Item, vaultName: String, reveal: Bool, style: Style, concealing: Bool = false) -> String {
        style.json ? OpOutput.json(OpOutput.ordered(OpOutput.itemJSON(item, vaultName: vaultName, concealing: concealing)))
            : OpOutput.itemHuman(item, vaultName: vaultName, reveal: reveal && !concealing, iso: style.iso, now: now())
    }

    // MARK: Writes

    /// Makes an approved write. `target` is the item for edit and delete; for create, its
    /// vault (and the new title).
    public func write(_ write: ItemWrite, target: ItemIdentity, env: [String: String]) -> ProxyResponse {
        let style = Style(flags: write.flags, env: env)
        return attempt {
            let generated = write.generatePassword?.generate()
            switch write.kind {
            case .create:
                let saved = try client.create(try write.creation(vaultId: target.vaultId, generated: generated)).get()
                return render(saved, vaultName: target.vaultName, reveal: false, style: style, concealing: true)
            case .edit:
                var item = try client.item(vaultId: target.vaultId, itemId: target.itemId).get()
                try write.apply(to: &item, generated: generated)
                let saved = try client.put(item).get()
                return render(saved, vaultName: target.vaultName, reveal: false, style: style, concealing: true)
            case .delete(let archive):
                try (archive ? client.archive(vaultId: target.vaultId, itemId: target.itemId)
                    : client.delete(vaultId: target.vaultId, itemId: target.itemId)).get()
                return ""
            }
        }
    }

    // MARK: Responses

    struct OpError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private func ok(_ text: String) -> ProxyResponse {
        ProxyResponse(exitCode: 0, stdout: Data(text.utf8), stderr: Data())
    }

    private func attempt(_ body: () throws -> String) -> ProxyResponse {
        attemptData { Data(try body().utf8) }
    }

    private func attemptData(_ body: () throws -> Data) -> ProxyResponse {
        do {
            return ProxyResponse(exitCode: 0, stdout: try body(), stderr: Data())
        } catch {
            return Self.error("\(error)", at: now())
        }
    }

    /// `[ERROR] 2026/11/18 10:21:04 <message>`, as `op` reports errors.
    public static func error(_ message: String, at date: Date = Date()) -> ProxyResponse {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return ProxyResponse(exitCode: 1, stdout: Data(), stderr: Data("[ERROR] \(f.string(from: date)) \(message)\n".utf8))
    }
}
