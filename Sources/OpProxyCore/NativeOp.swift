import Darwin
import Foundation

/// A 1Password `op` process that opProxy doesn't answer: one that opProxy passed through, or
/// one that never reached opProxy's `op`. 1Password's own prompt may be asking about it.
public enum NativeOp {
    /// Why `process` (a running 1Password `op`) didn't reach opProxy's `op`, from how it was
    /// started: its argv[0] and the PATH it was exec'd with. `shimDir` is `~/.opProxy/bin`.
    public static func whyDirect(argv0: String, path: String?, shimDir: String,
                                 isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String {
        if argv0.contains("/") { return "it ran \(abbreviated(argv0)) by its full path" }
        let shim = trimmed(shimDir)
        let dirs = (path ?? "").split(separator: ":").map { trimmed(String($0)) }
        guard let shimIndex = dirs.firstIndex(of: shim) else {
            return "\(abbreviated(shim)) isn't on its PATH"
        }
        if let first = dirs.firstIndex(where: { $0 != shim && !$0.isEmpty && isExecutable($0 + "/op") }), first < shimIndex {
            return "\(abbreviated(dirs[first])) comes before \(abbreviated(shim)) on its PATH"
        }
        return "it didn't go through opProxy's op"
    }

    /// The `op` command line to show and log, with the value of every `field=value`
    /// assignment hidden (as item writes put secrets there). Secret references stay.
    public static func displayed(_ argv: [String]) -> String {
        let shown = argv.map { arg -> String in
            guard !arg.hasPrefix("-"), !arg.hasPrefix("op://"), let eq = arg.firstIndex(of: "=") else { return arg }
            return String(arg[...eq]) + ItemWrite.hidden
        }
        return (["op"] + shown).map(shellQuote).joined(separator: " ")
    }

    /// `op <subcommand>`, with no arguments: what the log records of a passed-through call,
    /// whose arguments can be secrets.
    public static func subcommand(_ argv: [String]) -> String {
        (["op"] + OpCommand(argv: argv).subcommand).joined(separator: " ")
    }

    /// One line, at most `limit` characters: for log lines built from what a caller sent.
    public static func oneLine(_ s: String, limit: Int = 200) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    static func trimmed(_ dir: String) -> String {
        dir.count > 1 && dir.hasSuffix("/") ? String(dir.dropLast()) : dir
    }

    public static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=@%+,‹›".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension ProcessTree {
    /// This user's processes whose command name (the kernel's, from the executable) is `name`.
    public static func pids(named name: String) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // Room for processes started between the two calls.
        size += 32 * MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).compactMap { p in
            var comm = p.kp_proc.p_comm
            let command = withUnsafeBytes(of: &comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return command == name ? p.kp_proc.p_pid : nil
        }
    }

    /// The process's working directory, if this user may see it.
    public static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
