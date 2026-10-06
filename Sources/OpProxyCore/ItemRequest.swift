import Foundation

/// A command that can return secret values, reduced to the one item it reads.
///
/// `op read`, `op item get` and `op document get` each address exactly one item; reading
/// several at once needs stdin, which is never proxied. Only command lines built from
/// allowlisted flags qualify. The daemon resolves the item to its IDs itself and runs
/// `pinned(to:)`, so what runs is exactly the item that was checked and approved, whatever
/// 1Password's own name matching would have picked.
public struct ItemRequest: Equatable {
    public enum Kind: Equatable {
        case read(SecretReference)
        case itemGet
        case documentGet
    }

    public let kind: Kind
    /// The item as the caller named it: a title or an ID.
    public let item: String
    /// The vault as the caller named it, if it did.
    public let vault: String?
    /// `--account`, if given. The daemon falls back to `OP_ACCOUNT`.
    public let account: String?
    public let includeArchive: Bool
    let flags: [String: String]
    let argv: [String]
    /// Where the item (or, for `read`, the reference) sits in `argv`.
    let itemIndex: Int
    /// Where `--vault`'s value sits in `argv`, and whether it's the `--vault=…` form.
    let vaultIndex: (index: Int, inline: Bool)?

    public static func == (a: ItemRequest, b: ItemRequest) -> Bool { a.argv == b.argv }

    /// Flags every command may carry.
    static let globalFlags: Set<String> = ["--account", "--format", "--encoding", "--no-color", "--iso-timestamps", "--cache"]

    /// Each command's own allowed flags. Anything else sends the command to the real `op`.
    /// `--out-file` and its companions are handled by the shim and removed before parsing.
    static let commandFlags: [String: Set<String>] = [
        "read": ["--no-newline", "-n"],
        "item get": ["--vault", "--fields", "--reveal", "--otp", "--include-archive"],
        "document get": ["--vault", "--include-archive"],
    ]

    public struct Unsupported: Error, Equatable {
        public let reason: String
    }

    /// Parses `argv` (after `op`, without file flags) into an item request.
    public static func parse(_ argv: [String]) -> Result<ItemRequest, Unsupported> {
        func refuse(_ reason: String) -> Result<ItemRequest, Unsupported> { .failure(Unsupported(reason: reason)) }
        var words: [(index: Int, value: String)] = []
        var flags: [String: String] = [:]
        var vaultIndex: (index: Int, inline: Bool)?
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            if arg == "--" { return refuse("uses --") }
            guard arg.hasPrefix("-"), arg != "-" else {
                words.append((i, arg))
                i += 1
                continue
            }
            let eq = arg.hasPrefix("--") ? arg.firstIndex(of: "=") : nil
            let name = eq.map { String(arg[..<$0]) } ?? arg
            let inline = eq.map { String(arg[arg.index(after: $0)...]) }
            guard flags[name] == nil else { return refuse("repeats \(name)") }
            if OpCommand.valueFlags.contains(name) {
                if inline == nil {
                    guard i + 1 < argv.count else { return refuse("\(name) has no value") }
                    i += 1
                }
                flags[name] = inline ?? argv[i]
                if name == "--vault" { vaultIndex = (i, inline != nil) }
            } else {
                flags[name] = inline ?? ""
            }
            i += 1
        }
        let path = words.prefix(words.first?.value == "read" ? 1 : 2).map(\.value).joined(separator: " ")
        guard let allowed = commandFlags[path] else { return refuse("`op \(path)` doesn't read one item") }
        if let other = flags.keys.sorted().first(where: { !allowed.contains($0) && !globalFlags.contains($0) }) {
            return refuse("uses \(other)")
        }
        let positionals = words.dropFirst(path == "read" ? 1 : 2)
        guard positionals.count == 1, let target = positionals.first, !target.value.isEmpty else {
            return refuse("names \(positionals.count) items")
        }
        let vault = flags["--vault"]
        if vault?.isEmpty == true { return refuse("has an empty --vault") }
        let kind: Kind
        let item: String
        switch path {
        case "read":
            guard let ref = SecretReference(target.value), !ref.vault.isEmpty, !ref.item.isEmpty else {
                return refuse("isn't a secret reference")
            }
            (kind, item) = (.read(ref), ref.item)
        case "item get": (kind, item) = (.itemGet, target.value)
        default: (kind, item) = (.documentGet, target.value)
        }
        return .success(ItemRequest(kind: kind, item: item, vault: kind.reference?.vault ?? vault,
                                    account: flags["--account"], includeArchive: flags["--include-archive"] != nil,
                                    flags: flags, argv: argv, itemIndex: target.index, vaultIndex: vaultIndex))
    }

    /// `argv` with the item and vault replaced by `target`'s IDs.
    public func pinned(to target: ItemIdentity) -> [String] {
        var out = argv
        switch kind {
        case .read(let ref):
            out[itemIndex] = ref.pinned(vaultId: target.vaultId, itemId: target.itemId)
        case .itemGet, .documentGet:
            out[itemIndex] = target.itemId
            if let vaultIndex {
                out[vaultIndex.index] = vaultIndex.inline ? "--vault=\(target.vaultId)" : target.vaultId
            } else {
                out += ["--vault", target.vaultId]
            }
        }
        return out
    }

    // MARK: - Description for the approval dialog

    public struct Detail: Equatable {
        public enum Style: Equatable {
            case normal
            /// A default standing in for a missing value, e.g. "all fields".
            case placeholder
        }

        public let label: String
        public let value: String
        public let style: Style

        public init(label: String, value: String, style: Style = .normal) {
            self.label = label
            self.value = value
            self.style = style
        }
    }

    /// e.g. "Read a secret".
    public var action: String {
        switch kind {
        case .read: return "Read a secret"
        case .itemGet: return "Get an item"
        case .documentGet: return "Download a document"
        }
    }

    /// What the request reads from the item.
    public var details: [Detail] {
        var details: [Detail] = []
        switch kind {
        case .read(let ref):
            if let section = ref.section { details.append(Detail(label: "Section", value: section)) }
            details.append(Detail(label: "Field", value: ref.field))
            if let query = ref.query { details.append(Detail(label: "Options", value: query)) }
        case .itemGet:
            details.append(fieldsDetail)
        case .documentGet:
            details.append(Detail(label: "Contents", value: "the whole document", style: .placeholder))
        }
        if let account { details.append(Detail(label: "Account", value: account)) }
        return details
    }

    private var fieldsDetail: Detail {
        if let fields = flags["--fields"] { return Detail(label: "Fields", value: Self.readableFields(fields)) }
        if flags["--otp"] != nil { return Detail(label: "Fields", value: "one-time password") }
        return Detail(label: "Fields", value: "all fields", style: .placeholder)
    }

    /// Completes "opProxy is trying to let Claude … <summary>" in the Touch ID prompt.
    public func summary(_ target: ItemIdentity) -> String {
        let name = "“\(target.label)”"
        switch kind {
        case .read(let ref): return "read \(ref.field) from \(name)"
        case .itemGet:
            let fields = fieldsDetail
            return fields.style == .placeholder ? "get every field of \(name)" : "get \(fields.value) from \(name)"
        case .documentGet: return "download \(name)"
        }
    }

    /// `label=credential,label=username` → "credential, username"; `type=otp` → "type otp".
    static func readableFields(_ spec: String) -> String {
        spec.split(separator: ",").map { part -> String in
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { return String(part) }
            return kv[0] == "label" ? kv[1] : "\(kv[0]) \(kv[1])"
        }.joined(separator: ", ")
    }
}

private extension ItemRequest.Kind {
    var reference: SecretReference? {
        if case .read(let ref) = self { return ref }
        return nil
    }
}

/// One item, by the IDs 1Password knows it by, with its names for display.
public struct ItemIdentity: Equatable {
    public let itemId: String
    public let vaultId: String
    public let title: String
    public let vaultName: String

    public init(itemId: String, vaultId: String, title: String, vaultName: String) {
        self.itemId = itemId
        self.vaultId = vaultId
        self.title = title
        self.vaultName = vaultName
    }

    /// "Private / Chat webhook".
    public var label: String { "\(vaultName) / \(title)" }
}

/// `op item list --format json`, for working out which item a request means. Listings carry
/// no secret values.
public struct ItemCatalog {
    struct Entry: Decodable {
        struct Vault: Decodable {
            let id: String
            let name: String
        }
        let id: String
        let title: String
        let vault: Vault
    }

    public enum Match: Equatable {
        case one(ItemIdentity)
        case none
        case many([ItemIdentity])
    }

    private let entries: [Entry]

    public init(json: Data) throws {
        entries = try JSONDecoder().decode([Entry].self, from: json)
    }

    /// The item `item` names: by ID, else by exact title, else by title in any case. A vault
    /// narrows the search, by ID or by name in any case.
    public func resolve(item: String, vault: String?) -> Match {
        let inVault = entries.filter { e in
            vault.map { e.vault.id == $0 || e.vault.name.caseInsensitiveCompare($0) == .orderedSame } ?? true
        }
        let tiers: [(Entry) -> Bool] = [
            { $0.id == item },
            { $0.title == item },
            { $0.title.caseInsensitiveCompare(item) == .orderedSame },
        ]
        for matches in tiers {
            let found = inVault.filter(matches).map {
                ItemIdentity(itemId: $0.id, vaultId: $0.vault.id, title: $0.title, vaultName: $0.vault.name)
            }
            switch found.count {
            case 0: continue
            case 1: return .one(found[0])
            default: return .many(found)
            }
        }
        return .none
    }
}
