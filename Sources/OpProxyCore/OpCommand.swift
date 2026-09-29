import Foundation

/// How the shim should treat an `op` invocation.
public enum Routing: Equatable {
    /// Exec the real `op` unchanged: 1Password handles it (and prompts) exactly as before.
    case passthrough(reason: String)
    /// Run through the daemon's long-lived authorized session.
    case proxy(ProxyPlan)
}

public struct ProxyPlan: Equatable {
    public let requiresApproval: Bool
    /// What the daemon runs. Differs from the caller's argv only when the caller asked for
    /// `--out-file`: the daemon's cwd is not the caller's, so the shim writes the file.
    public let daemonArgv: [String]
    public let outFile: OutFile?
}

/// `--out-file` handling that `op read` / `op document get` would otherwise do itself.
public struct OutFile: Equatable {
    public let path: String
    public let mode: Int
    public let force: Bool
}

/// A parsed `op` command line: the subcommand path plus its flags and positionals.
public struct OpCommand: Equatable {
    public let argv: [String]
    public let subcommand: [String]
    public let positionals: [String]
    public let flags: [String: String]

    /// Flags that take a value, so `--vault Private` is not read as a positional.
    static let valueFlags: Set<String> = [
        "--account", "--cache-dir", "--config", "--encoding", "--format", "--session",
        "--vault", "--fields", "--categories", "--tags", "--out-file", "-o", "--file-mode",
        "--include-categories", "--exclude-categories", "--attribute",
    ]

    /// Subcommand groups whose second word is also part of the command path.
    static let groups: Set<String> = [
        "item", "vault", "document", "account", "user", "group", "connect", "events-api",
        "service-account", "plugin",
    ]

    public init(argv: [String]) {
        self.argv = argv
        var subcommand: [String] = []
        var positionals: [String] = []
        var flags: [String: String] = [:]
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            if arg == "--" {
                positionals.append(contentsOf: argv[(i + 1)...])
                break
            }
            if arg.hasPrefix("-") && arg != "-" {
                if let eq = arg.firstIndex(of: "="), arg.hasPrefix("--") {
                    flags[String(arg[..<eq])] = String(arg[arg.index(after: eq)...])
                } else if Self.valueFlags.contains(arg), i + 1 < argv.count {
                    flags[arg] = argv[i + 1]
                    i += 1
                } else {
                    flags[arg] = ""
                }
            } else if subcommand.isEmpty
                        || (subcommand.count == 1 && Self.groups.contains(subcommand[0])) {
                subcommand.append(arg)
            } else {
                positionals.append(arg)
            }
            i += 1
        }
        self.subcommand = subcommand
        self.positionals = positionals
        self.flags = flags
    }

    public var routing: Routing {
        let path = subcommand.joined(separator: " ")
        guard let requiresApproval = Self.proxiedCommands[path] else {
            return .passthrough(reason: "`op \(path)` is not a read-only command opProxy handles")
        }
        // The daemon has no stdin and a different cwd and config.
        if positionals.contains("-") { return .passthrough(reason: "reads items from stdin") }
        for flag in ["--config", "--session", "--help", "-h"] where flags[flag] != nil {
            return .passthrough(reason: "uses \(flag)")
        }
        let outPath = flags["--out-file"] ?? flags["-o"]
        guard let outPath else {
            return .proxy(ProxyPlan(requiresApproval: requiresApproval, daemonArgv: argv, outFile: nil))
        }
        guard path == "read" || path == "document get", !outPath.isEmpty else {
            return .passthrough(reason: "uses --out-file")
        }
        let mode = flags["--file-mode"].flatMap { Int($0, radix: 8) } ?? 0o600
        let force = flags["--force"] != nil || flags["-f"] != nil
        return .proxy(ProxyPlan(requiresApproval: requiresApproval,
                                daemonArgv: Self.removingFileFlags(argv),
                                outFile: OutFile(path: outPath, mode: mode, force: force)))
    }

    static func removingFileFlags(_ argv: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            if arg == "--" { out.append(contentsOf: argv[i...]); break }
            if ["-o", "--out-file", "--file-mode"].contains(arg) { i += 2; continue }
            if arg.hasPrefix("--out-file=") || arg.hasPrefix("--file-mode=") || arg == "--force" || arg == "-f" {
                i += 1; continue
            }
            out.append(arg)
            i += 1
        }
        return out
    }

    /// Read-only commands the daemon runs, and whether each needs the user's approval: only
    /// the ones that can return secret values do. Listings and account metadata don't.
    /// Everything else (run, inject, item share, signin, plugin run, writes, …) never runs in
    /// the daemon's authorized session, so 1Password prompts for it as usual.
    static let proxiedCommands: [String: Bool] = [
        "read": true,
        "item get": true,
        "document get": true,
        "item list": false,
        "document list": false,
        "vault get": false,
        "vault list": false,
        "whoami": false,
        "account list": false,
        "account get": false,
    ]

    // MARK: - Description for the approval dialog

    public struct Detail: Equatable {
        public enum Style: Equatable {
            case normal
            /// A default standing in for a missing value, e.g. "any vault".
            case placeholder
            /// Worth a second look, e.g. revealing concealed values.
            case warning
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

    public struct Description: Equatable {
        /// e.g. "Read a secret".
        public let action: String
        /// The item or document being accessed: what the user is really approving.
        public let subject: String?
        /// Everything else about the request.
        public let details: [Detail]
        /// Completes "opProxy is trying to let Claude … <summary>" in the Touch ID prompt.
        public let summary: String

        init(action: String, subject: String? = nil, details: [Detail], summary: String) {
            self.action = action
            self.subject = subject
            self.details = details
            self.summary = summary
        }
    }

    public var description: Description {
        let account = flags["--account"].map { [Detail(label: "Account", value: $0)] } ?? []
        switch subcommand.joined(separator: " ") {
        case "read":
            if let ref = positionals.first, let parsed = SecretReference(ref) {
                var details = [Detail(label: "Vault", value: parsed.vault)]
                if let section = parsed.section { details.append(Detail(label: "Section", value: section)) }
                details.append(Detail(label: "Field", value: parsed.field))
                if let query = parsed.query { details.append(Detail(label: "Options", value: query)) }
                return Description(action: "Read a secret", subject: parsed.item, details: details + account,
                                   summary: "read \(parsed.vault)/\(parsed.item)/\(parsed.field)")
            }
        case "item get":
            if let item = positionals.first {
                let vault = flags["--vault"]
                let fields = flags["--fields"]
                var details = [vault.map { Detail(label: "Vault", value: $0) } ?? Detail(label: "Vault", value: "any vault", style: .placeholder)]
                let fieldNames = fields.map(Self.readableFields)
                if let fieldNames {
                    details.append(Detail(label: "Fields", value: fieldNames))
                } else if flags["--otp"] != nil {
                    details.append(Detail(label: "Fields", value: "one-time password"))
                } else {
                    details.append(Detail(label: "Fields", value: "all fields", style: .placeholder))
                }
                let revealed = flags["--reveal"] != nil || flags["--otp"] != nil
                details.append(revealed ? Detail(label: "Reveals secrets", value: "yes", style: .warning)
                                        : Detail(label: "Reveals secrets", value: "no"))
                let where_ = vault.map { " in \($0)" } ?? ""
                let what = fieldNames.map { " (\($0))" } ?? (flags["--otp"] != nil ? " (OTP)" : "")
                return Description(action: "Get an item", subject: item, details: details + account,
                                   summary: "get “\(item)”\(where_)\(what)")
            }
        case "document get":
            if let doc = positionals.first {
                let vault = flags["--vault"]
                return Description(action: "Download a document", subject: doc,
                                   details: [vault.map { Detail(label: "Vault", value: $0) }
                                                ?? Detail(label: "Vault", value: "any vault", style: .placeholder)] + account,
                                   summary: "download document “\(doc)”" + (vault.map { " from \($0)" } ?? ""))
            }
        case "item list":
            let vault = flags["--vault"]
            var details = [vault.map { Detail(label: "Vault", value: $0) } ?? Detail(label: "Vault", value: "all vaults", style: .placeholder)]
            if let c = flags["--categories"] { details.append(Detail(label: "Categories", value: c)) }
            if let t = flags["--tags"] { details.append(Detail(label: "Tags", value: t)) }
            return Description(action: "List items", details: details + account,
                               summary: "list items in " + (vault ?? "all vaults"))
        case "vault list":
            return Description(action: "List vaults", details: account, summary: "list vaults")
        case "vault get":
            if let vault = positionals.first {
                return Description(action: "Get vault details", details: [Detail(label: "Vault", value: vault)] + account,
                                   summary: "get vault “\(vault)”")
            }
        default:
            break
        }
        return Description(action: "Run a 1Password command", details: account,
                           summary: "run op " + argv.joined(separator: " "))
    }
}

extension OpCommand {
    /// 1Password's opaque 26-character item and vault IDs, as opposed to names.
    public static func looksLikeID(_ s: String) -> Bool {
        s.count == 26 && s.allSatisfy { ($0.isLowercase && $0.isASCII) || $0.isNumber }
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

/// `op://vault/item[/section]/field[?query]`
public struct SecretReference: Equatable {
    public let vault: String
    public let item: String
    public let section: String?
    public let field: String
    public let query: String?

    public init?(_ ref: String) {
        guard ref.hasPrefix("op://") else { return nil }
        var rest = String(ref.dropFirst("op://".count))
        var query: String?
        if let q = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: q)...])
            rest = String(rest[..<q])
        }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 3: (vault, item, section, field) = (parts[0], parts[1], nil, parts[2])
        case 4: (vault, item, section, field) = (parts[0], parts[1], parts[2], parts[3])
        default: return nil
        }
        self.query = query
    }
}
