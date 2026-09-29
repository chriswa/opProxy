import Darwin
import Foundation

public struct ProcessEntry: Equatable {
    public let pid: pid_t
    public let ppid: pid_t
    public let executable: String
    public let argv: [String]
    /// The environment of the process's latest exec (later `export`s aren't visible).
    public let env: [String: String]
    /// Seconds since 1970; with `pid`, identifies this process across PID reuse.
    public let startTime: Double
    /// Controlling terminal, e.g. "ttys012".
    public let tty: String?

    public init(pid: pid_t, ppid: pid_t, executable: String, argv: [String], env: [String: String] = [:],
                startTime: Double = 0, tty: String? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.executable = executable
        self.argv = argv
        self.env = env
        self.startTime = startTime
        self.tty = tty
    }

    public var name: String { (executable as NSString).lastPathComponent }

    /// The executable's name and argv[0]'s, which differ for wrappers like cursor-agent's
    /// `exec -a "$0" node index.js`.
    public var names: Set<String> {
        var names: Set<String> = [name]
        if let argv0 = argv.first { names.insert((argv0 as NSString).lastPathComponent) }
        return names
    }
}

public enum ProcessTree {
    public static func entry(_ pid: pid_t) -> ProcessEntry? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let args = arguments(pid)
        let start = info.kp_proc.p_un.__p_starttime
        let tdev = info.kp_eproc.e_tdev
        let tty = tdev == -1 ? nil : devname(tdev, S_IFCHR).map { String(cString: $0) }
        return ProcessEntry(pid: pid, ppid: info.kp_eproc.e_ppid, executable: args?.executable ?? "",
                            argv: args?.argv ?? [], env: args?.env ?? [:],
                            startTime: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000, tty: tty)
    }

    /// `pid` and its ancestors, nearest first, stopping before launchd.
    public static func ancestry(of pid: pid_t, limit: Int = 16) -> [ProcessEntry] {
        var chain: [ProcessEntry] = []
        var current = pid
        while current > 1, chain.count < limit, let e = entry(current) {
            chain.append(e)
            current = e.ppid
        }
        return chain
    }

    struct Arguments {
        let executable: String
        let argv: [String]
        let env: [String: String]
    }

    static func arguments(_ pid: pid_t) -> Arguments? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buf[..<size]))
    }

    /// Layout: Int32 argc, exec path, NUL padding, argc NUL-terminated argv strings, then
    /// NUL-terminated `KEY=value` environment strings up to an empty one.
    static func parseProcArgs(_ buf: [UInt8]) -> Arguments? {
        guard buf.count > 4 else { return nil }
        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = 4
        func cString() -> String {
            let start = i
            while i < buf.count, buf[i] != 0 { i += 1 }
            return String(decoding: buf[start..<i], as: UTF8.self)
        }
        let exe = cString()
        while i < buf.count, buf[i] == 0 { i += 1 }
        var argv: [String] = []
        while argv.count < argc, i < buf.count {
            argv.append(cString())
            i += 1
        }
        var env: [String: String] = [:]
        while i < buf.count {
            let entry = cString()
            i += 1
            if entry.isEmpty { break }
            if let eq = entry.firstIndex(of: "=") {
                env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
            }
        }
        return Arguments(executable: exe, argv: argv, env: env)
    }
}

/// What the agent actually ran, recovered from the process tree above the shim.
public struct CallerContext: Equatable, Codable {
    /// The agent tool call's shell command, e.g. `KEY=$(op read …) && curl …`.
    public let toolCommand: String?
    /// The shim's parent when it is not the tool shell itself, e.g. a skill script.
    public let viaProcess: String?

    public init(toolCommand: String?, viaProcess: String?) {
        self.toolCommand = toolCommand
        self.viaProcess = viaProcess
    }

    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh"]

    /// `chain` is the shim's ancestry, nearest first (chain[0] is the shim).
    /// `chain` is the shim's ancestry, nearest first (chain[0] is the shim); `agentPid` is
    /// the verified agent process.
    public static func from(chain: [ProcessEntry], agentPid: pid_t?) -> CallerContext {
        guard chain.count > 1 else { return CallerContext(toolCommand: nil, viaProcess: nil) }
        let ancestors = Array(chain.dropFirst())
        let agentIndex = ancestors.firstIndex { $0.pid == agentPid }
            ?? ancestors.firstIndex { AgentKind.matching($0) != nil }
        let candidates = agentIndex.map { Array(ancestors[..<$0]) } ?? ancestors
        // The outermost `sh -c` below the agent is the tool call.
        let toolShellIndex = candidates.lastIndex { shellCommand($0.argv) != nil }
        let toolCommand = toolShellIndex.flatMap { shellCommand(candidates[$0].argv) }.map(unwrapClaudeCommand)
        // `$(op …)` forks subshells that share the tool shell's argv; skip those to find a
        // real intermediary such as a skill script.
        let intermediary: ProcessEntry?
        if let t = toolShellIndex {
            intermediary = candidates[..<t].first { $0.argv != candidates[t].argv }
        } else {
            intermediary = ancestors.first
        }
        let via = intermediary.map { $0.argv.isEmpty ? $0.executable : $0.argv.joined(separator: " ") }
        return CallerContext(toolCommand: toolCommand, viaProcess: via)
    }

    /// The command string of `<shell> [-l] -c <cmd>` (also `-lc`, `-ic`).
    static func shellCommand(_ argv: [String]) -> String? {
        guard let first = argv.first else { return nil }
        let name = (first as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard shells.contains(name) else { return nil }
        for (i, arg) in argv.enumerated().dropFirst() {
            guard arg.hasPrefix("-"), !arg.hasPrefix("--") else { break }
            if arg.contains("c") { return i + 1 < argv.count ? argv[i + 1] : nil }
        }
        return nil
    }

    /// Claude Code wraps each Bash call as
    /// `source <snapshot> … && eval '<cmd>' < /dev/null && pwd -P >| <file>`.
    static func unwrapClaudeCommand(_ command: String) -> String {
        guard command.contains("shell-snapshots/"), let range = command.range(of: "&& eval ") else {
            return command
        }
        return ShellWords.firstWord(command[range.upperBound...]) ?? command
    }
}

enum ShellWords {
    /// Parses one POSIX shell word (quotes and backslashes) from the start of `s`.
    static func firstWord(_ s: Substring) -> String? {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex, s[i] == " " { i = s.index(after: i) }
        let start = i
        while i < s.endIndex {
            let c = s[i]
            if c == " " || c == "\t" || c == "\n" { break }
            if c == "'" {
                guard let close = s[s.index(after: i)...].firstIndex(of: "'") else { return nil }
                out += s[s.index(after: i)..<close]
                i = s.index(after: close)
            } else if c == "\"" {
                i = s.index(after: i)
                while i < s.endIndex, s[i] != "\"" {
                    if s[i] == "\\", s.index(after: i) < s.endIndex { i = s.index(after: i) }
                    out.append(s[i])
                    i = s.index(after: i)
                }
                guard i < s.endIndex else { return nil }
                i = s.index(after: i)
            } else if c == "\\", s.index(after: i) < s.endIndex {
                out.append(s[s.index(after: i)])
                i = s.index(i, offsetBy: 2)
            } else {
                out.append(c)
                i = s.index(after: i)
            }
        }
        return i == start ? nil : out
    }
}
