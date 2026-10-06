import Foundation

/// Shim → daemon, one JSON line.
public struct ProxyRequest: Codable {
    /// The agent session the caller's environment claims, if any. The daemon decides from
    /// the process tree whether an agent is really behind the call.
    public let session: AgentSession?
    /// `SpacetermSurface.nodeId(environment:)`, for the dialog's title and link. Display only.
    public let spacetermNodeId: String?
    /// The caller's exact argv (after `op`); this is what an approval covers. The daemon
    /// derives routing from it itself and never trusts the client's view of it.
    public let argv: [String]
    public let env: [String: String]
    public let cwd: String

    public init(session: AgentSession?, spacetermNodeId: String?, argv: [String], env: [String: String], cwd: String) {
        self.session = session
        self.spacetermNodeId = spacetermNodeId
        self.argv = argv
        self.env = env
        self.cwd = cwd
    }

    /// `OP_*` variables that only change `op`'s output or account selection. Anything that
    /// could redirect its config, auth or plugins (OP_CONFIG_DIR, OP_BIOMETRIC_UNLOCK_ENABLED,
    /// …) is dropped. Credentials that bypass the desktop app never reach the daemon: the
    /// shim passes those invocations straight through.
    public static let forwardedVariables: Set<String> = [
        "OP_ACCOUNT", "OP_FORMAT", "OP_ISO_TIMESTAMPS", "OP_INCLUDE_ARCHIVE", "OP_CACHE", "OP_DEBUG",
    ]

    public static func forwardedEnvironment(_ env: [String: String]) -> [String: String] {
        env.filter { forwardedVariables.contains($0.key) }
    }

    public static func bypassesDesktopApp(_ env: [String: String]) -> Bool {
        env.keys.contains { $0 == "OP_SERVICE_ACCOUNT_TOKEN" || $0 == "OP_CONNECT_TOKEN" || $0.hasPrefix("OP_SESSION_") }
    }
}

/// Daemon → shim, one JSON document then EOF.
public struct ProxyResponse: Codable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    /// The daemon won't vouch for this caller; the shim should exec the real `op` instead.
    public let passthrough: Bool?

    public init(exitCode: Int32, stdout: Data, stderr: Data, passthrough: Bool? = nil) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.passthrough = passthrough
    }

    public static let usePassthrough = ProxyResponse(exitCode: 0, stdout: Data(), stderr: Data(), passthrough: true)

    public static func failure(_ message: String) -> ProxyResponse {
        ProxyResponse(exitCode: 1, stdout: Data(), stderr: Data(("[ERROR] opProxy: " + message + "\n").utf8))
    }
}

/// Everything the daemon's socket accepts: a proxied `op` call or a control command.
public enum DaemonMessage: Codable {
    case proxy(ProxyRequest)
    /// Replies with `DaemonStatus`.
    case status
    /// Authorizes a fresh 1Password session and switches to it; replies with `DaemonStatus`.
    case refresh
}

public struct DaemonStatus: Codable {
    public let auth: AuthWindow
    public let activeApprovals: Int
    /// Set when a refresh failed, e.g. the 1Password prompt was cancelled.
    public let error: String?

    public init(auth: AuthWindow, activeApprovals: Int, error: String?) {
        self.auth = auth
        self.activeApprovals = activeApprovals
        self.error = error
    }
}

/// Daemon → session holder, one JSON line per `op` run.
public struct HolderRequest: Codable {
    public let id: Int
    public let argv: [String]
    public let env: [String: String]
    public let timeout: TimeInterval

    public init(id: Int, argv: [String], env: [String: String], timeout: TimeInterval) {
        self.id = id
        self.argv = argv
        self.env = env
        self.timeout = timeout
    }
}

public struct HolderReply: Codable {
    public let id: Int
    public let response: ProxyResponse

    public init(id: Int, response: ProxyResponse) {
        self.id = id
        self.response = response
    }
}
