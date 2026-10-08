import Foundation

/// Filesystem locations. Tests redirect them with the `OPPROXY_HOME` and `OPPROXY_REAL_OP`
/// knobs, which release builds ignore.
public struct Paths {
    public let stateDir: URL
    /// Where `op` is looked up. It is verified against 1Password's signature before every run.
    public let realOpCandidates: [String]

    public var socket: URL { stateDir.appendingPathComponent("daemon.sock") }
    public var approvals: URL { stateDir.appendingPathComponent("approvals.json") }
    public var log: URL { stateDir.appendingPathComponent("daemon.log") }
    /// While this file exists, the shim hands every call straight to the real `op`.
    public var disabledFlag: URL { stateDir.appendingPathComponent("disabled") }

    public var isDisabled: Bool { FileManager.default.fileExists(atPath: disabledFlag.path) }

    /// Turns proxying on or off everywhere at once. Anyone could create the flag, but that only
    /// restores 1Password's own prompts, so it needs no protection.
    public func setDisabled(_ disabled: Bool) throws {
        try ensureStateDir()
        if disabled {
            FileManager.default.createFile(atPath: disabledFlag.path, contents: nil)
        } else if isDisabled {
            try FileManager.default.removeItem(at: disabledFlag)
        }
    }

    /// Secure Enclave key blob that signs approvals.
    public var approvalKey: URL { stateDir.appendingPathComponent("approval-key.se") }
    /// Where pending approvals are published for the Spaceterm phone app (APPROVAL_FEED.md).
    public var approvalFeed: URL { stateDir.appendingPathComponent("approval-feed.sock") }
    /// This Mac's ID for paired phones (MacIdentity).
    public var macID: URL { stateDir.appendingPathComponent("mac-id") }
    /// Optional settings (OpProxyConfig).
    public var config: URL { stateDir.appendingPathComponent("config.json") }
    /// The paired iPhones' CloudKit zones the Mac has joined.
    public var cloudLinks: URL { stateDir.appendingPathComponent("cloud-links.json") }
    /// Phones allowed to answer approvals, each entry signed with the approval key.
    public var pairedDevices: URL { stateDir.appendingPathComponent("paired-devices.json") }

    public init(environment env: [String: String] = ProcessInfo.processInfo.environment) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        stateDir = TestKnobs.value("OPPROXY_HOME", in: env).map(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent(".opProxy")
        realOpCandidates = TestKnobs.value("OPPROXY_REAL_OP", in: env).map { [$0] }
            ?? ["/opt/homebrew/bin/op", "/usr/local/bin/op"]
    }

    /// First candidate that exists; the shim's passthrough execs it directly.
    public var realOp: String {
        realOpCandidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? realOpCandidates[0]
    }

    public func ensureStateDir() throws {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}
