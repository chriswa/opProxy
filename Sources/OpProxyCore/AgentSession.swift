import Foundation

public enum AgentKind: String, Codable, CaseIterable {
    case claude, codex, cursor

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    /// Environment variables that carry this agent's session ID, most specific first.
    var sessionIdVariables: [String] {
        switch self {
        case .claude: return ["CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID"]
        case .codex: return ["CODEX_THREAD_ID"]
        // Spaceterm keys Cursor surfaces by conversation ID.
        case .cursor: return ["CURSOR_CONVERSATION_ID", "CURSOR_AGENT_CHAT_ID"]
        }
    }

    /// Process names of the agent's own binary, for finding it in a process tree.
    var processNames: Set<String> {
        switch self {
        case .claude: return ["claude"]
        case .codex: return ["codex"]
        case .cursor: return ["cursor-agent"]
        }
    }

    public static func matching(_ process: ProcessEntry) -> AgentKind? {
        allCases.first { !$0.processNames.isDisjoint(with: process.names) }
    }
}

/// The agent session a shim invocation belongs to, identified from its environment.
public struct AgentSession: Codable, Equatable {
    public let agent: AgentKind
    public let sessionId: String

    public init(agent: AgentKind, sessionId: String) {
        self.agent = agent
        self.sessionId = sessionId
    }

    /// Agents inherit each other's environment when nested (Codex launched from Claude sees
    /// both session variables), so when several are present the nearest agent process in
    /// `ancestry` decides.
    public static func detect(environment env: [String: String],
                              ancestry: () -> [ProcessEntry] = { [] }) -> AgentSession? {
        var candidates: [AgentKind: String] = [:]
        for agent in AgentKind.allCases {
            if let id = agent.sessionIdVariables.lazy.compactMap({ nonEmpty(env[$0]) }).first {
                candidates[agent] = id
            }
        }
        let chosen: AgentKind?
        if candidates.count > 1 {
            chosen = ancestry().lazy.compactMap(AgentKind.matching)
                .first { candidates[$0] != nil }
                ?? AgentKind.allCases.first { candidates[$0] != nil }
        } else {
            chosen = candidates.keys.first
        }
        guard let chosen, let id = candidates[chosen] else { return nil }
        return AgentSession(agent: chosen, sessionId: id)
    }
}

func nonEmpty(_ s: String?) -> String? {
    guard let s, !s.isEmpty else { return nil }
    return s
}
