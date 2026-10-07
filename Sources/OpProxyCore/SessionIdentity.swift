import Darwin
import Foundation

/// The agent process a request really comes from: the nearest ancestor of the caller that is
/// a genuinely signed agent binary. The session ID can't be verified (it lives only in the
/// tool shell's environment, which `exec env …` can rewrite and macOS won't reveal for
/// /bin/zsh), so it is taken as claimed. An agent that claims none is identified by its
/// process (`agentInstance`), which a caller can't forge.
public struct SessionIdentity: Equatable {
    public let agent: AgentKind
    public let agentPid: pid_t
    /// PID plus start time of the agent process.
    public let agentInstance: String

    public static func verify(peer: pid_t) -> SessionIdentity? {
        from(chain: ProcessTree.ancestry(of: peer), isGenuine: AgentKind.verify)
    }

    /// `chain` is nearest first; chain[0] is the caller itself.
    static func from(chain: [ProcessEntry], isGenuine: (ProcessEntry) -> AgentKind?) -> SessionIdentity? {
        for process in chain.dropFirst() {
            if let agent = isGenuine(process) {
                return SessionIdentity(agent: agent, agentPid: process.pid, agentInstance: instance(of: process))
            }
        }
        return nil
    }
}

func instance(of process: ProcessEntry) -> String {
    #if OPPROXY_TESTING
    // Fake agents in tests name their instance, so separate calls can share approvals.
    if process.argv.first == "opproxy-fake-agent", process.argv.count > 2 { return "fake:" + process.argv[2] }
    #endif
    return "\(process.pid)@\(Int64(process.startTime * 1_000_000))"
}

extension AgentKind {
    /// Identifiers and Team IDs of the vendors' signed binaries.
    var signingRequirement: SigningRequirement {
        switch self {
        case .claude: return SigningRequirement(identifier: "com.anthropic.claude-code", team: "Q6L2SF6YDW")
        case .codex: return SigningRequirement(identifier: "codex", team: "2DC432GLL2")
        // cursor-agent is a script that runs a Node.js-signed node; see `verify`.
        case .cursor: return SigningRequirement(identifier: "node", team: "HX7739G8FX")
        }
    }

    /// The agent `process` genuinely is, if any.
    static func verify(_ process: ProcessEntry) -> AgentKind? {
        #if OPPROXY_TESTING
        if process.argv.first == "opproxy-fake-agent" { return .claude }
        #endif
        guard let kind = matching(process), CodeSignature.process(process.pid, satisfies: kind.signingRequirement) else {
            return nil
        }
        if kind == .cursor {
            // Any node can be renamed cursor-agent, so also require Cursor's own entry point
            // beside that node and no NODE_OPTIONS preloads (node's env is readable, unlike
            // /bin/zsh's). Weaker than a vendor signature.
            let dir = (process.executable as NSString).deletingLastPathComponent
            let script = process.argv.dropFirst().first { !$0.hasPrefix("-") }
            guard script == dir + "/index.js", process.env["NODE_OPTIONS"] == nil else { return nil }
        }
        return kind
    }
}
