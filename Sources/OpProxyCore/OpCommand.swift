import Foundation

/// How the shim should treat an `op` invocation.
public enum Routing: Equatable {
    /// Exec the real `op` unchanged: 1Password handles it (and prompts) exactly as before.
    case passthrough(reason: String)
    /// Run through the daemon's long-lived authorized session.
    case proxy(ProxyPlan)
}

public struct ProxyPlan: Equatable {
    /// Set for commands that can return secret values, which need the user's approval: the
    /// one item they read. Nil for metadata.
    public let item: ItemRequest?
    /// The caller's argv without `--out-file` and its companions: the daemon's cwd is not the
    /// caller's, so the shim writes the file. For an item request the daemon runs this with
    /// the item pinned to its IDs.
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
        guard let readsSecrets = Self.proxiedCommands[path] else {
            return .passthrough(reason: "`op \(path)` is not a read-only command opProxy handles")
        }
        // The daemon has no stdin and a different cwd and config.
        if positionals.contains("-") { return .passthrough(reason: "reads items from stdin") }
        for flag in ["--config", "--session", "--help", "-h"] where flags[flag] != nil {
            return .passthrough(reason: "uses \(flag)")
        }
        var daemonArgv = argv
        var outFile: OutFile?
        if let outPath = flags["--out-file"] ?? flags["-o"] {
            guard path == "read" || path == "document get", !outPath.isEmpty else {
                return .passthrough(reason: "uses --out-file")
            }
            let mode = flags["--file-mode"].flatMap { Int($0, radix: 8) } ?? 0o600
            let force = flags["--force"] != nil || flags["-f"] != nil
            daemonArgv = Self.removingFileFlags(argv)
            outFile = OutFile(path: outPath, mode: mode, force: force)
        }
        guard readsSecrets else { return .proxy(ProxyPlan(item: nil, daemonArgv: daemonArgv, outFile: outFile)) }
        switch ItemRequest.parse(daemonArgv) {
        case .success(let item): return .proxy(ProxyPlan(item: item, daemonArgv: daemonArgv, outFile: outFile))
        case .failure(let unsupported): return .passthrough(reason: unsupported.reason)
        }
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

    /// Read-only commands the daemon runs, and whether each can return secret values, which
    /// need the user's approval. Listings and account metadata don't.
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
}

/// `op://vault/item[/section]/field[?query]`
public struct SecretReference: Equatable {
    public let vault: String
    public let item: String
    public let section: String?
    public let field: String
    public let query: String?
    private let raw: String

    public init?(_ ref: String) {
        guard ref.hasPrefix("op://") else { return nil }
        raw = ref
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

    /// This reference with its vault and item replaced by IDs; the rest is kept verbatim.
    func pinned(vaultId: String, itemId: String) -> String {
        "op://\(vaultId)/\(itemId)/" + raw.dropFirst("op://\(vault)/\(item)/".count)
    }
}
