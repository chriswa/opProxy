import Foundation

/// What an approval covers: one agent session, in one running agent process, running one
/// exact `op` command line. `env` holds the forwarded `OP_*` variables, since e.g.
/// `OP_ACCOUNT` changes what the same argv reads.
public struct ApprovalKey: Codable, Hashable {
    public let agent: AgentKind
    public let sessionId: String
    /// `SessionIdentity.agentInstance`: a resumed session is a new process and re-prompts.
    public let agentInstance: String
    public let argv: [String]
    public let env: [String: String]

    public init(agent: AgentKind, sessionId: String, agentInstance: String, argv: [String], env: [String: String]) {
        self.agent = agent
        self.sessionId = sessionId
        self.agentInstance = agentInstance
        self.argv = argv
        self.env = env
    }
}

public struct Approval: Codable, Equatable {
    public let key: ApprovalKey
    public let approvedAt: Date
    public let expiresAt: Date
    /// Spaceterm title at approval time, for `opProxy list` and the menu. Display only, so unsigned.
    public let sessionLabel: String?
    /// The item's name as the dialog showed it. Display only, so unsigned.
    public let itemLabel: String?
    /// Signature over `signedPayload`, made with the Touch ID-gated approval key.
    public let signature: Data?
    /// For approvals given on a paired phone, which can't use the Mac's approval key: the
    /// phone's signed statement, whose challenge commits to `signedPayload`.
    public let deviceProof: DeviceProof?

    init(key: ApprovalKey, approvedAt: Date, expiresAt: Date, sessionLabel: String?, itemLabel: String?,
         signature: Data?, deviceProof: DeviceProof? = nil) {
        self.key = key
        self.approvedAt = approvedAt
        self.expiresAt = expiresAt
        self.sessionLabel = sessionLabel
        self.itemLabel = itemLabel
        self.signature = signature
        self.deviceProof = deviceProof
    }

    /// Canonical bytes covering everything that grants access.
    public var signedPayload: Data {
        Self.payload(key: key, approvedAt: approvedAt, expiresAt: expiresAt)
    }

    /// `approvedAt` and `expiresAt` must be whole seconds, or the payload re-derived from the
    /// ISO 8601 file won't match.
    public static func payload(key: ApprovalKey, approvedAt: Date, expiresAt: Date) -> Data {
        struct Signed: Encodable {
            let version = 1
            let key: ApprovalKey
            let approvedAt: Date
            let expiresAt: Date
        }
        return try! ApprovalStore.encoder.encode(Signed(key: key, approvedAt: approvedAt, expiresAt: expiresAt))
    }
}

/// Approvals persisted as JSON, each signed; entries whose signature doesn't verify (forged,
/// edited, or replayed onto another session) are ignored. An entry is signed either by the
/// Mac's approval key or, when approved on a phone, carries that phone's proof instead.
/// Not thread-safe: the daemon uses it from one queue.
public final class ApprovalStore {
    public static let defaultTTL: TimeInterval = 7 * 24 * 60 * 60

    private let url: URL
    private let ttl: TimeInterval
    private let now: () -> Date
    private let verify: (_ payload: Data, _ signature: Data) -> Bool
    private let verifyDevice: (Approval) -> Bool
    private var approvals: [Approval] = []
    private var loadedModification: Date?

    public init(url: URL, ttl: TimeInterval = ApprovalStore.defaultTTL, now: @escaping () -> Date = Date.init,
                verify: @escaping (_ payload: Data, _ signature: Data) -> Bool,
                verifyDevice: @escaping (Approval) -> Bool = { _ in false }) {
        self.url = url
        self.ttl = ttl
        self.now = now
        self.verify = verify
        self.verifyDevice = verifyDevice
        reloadIfChanged()
    }

    private func isValid(_ a: Approval) -> Bool {
        if let signature = a.signature, verify(a.signedPayload, signature) { return true }
        return a.deviceProof != nil && verifyDevice(a)
    }

    /// Picks up `opProxy revoke` edits made by another process.
    private func reloadIfChanged() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard modified != loadedModification else { return }
        loadedModification = modified
        let data = try? Data(contentsOf: url)
        approvals = data.flatMap { try? Self.decoder.decode([Approval].self, from: $0) } ?? []
    }

    /// Unexpired entries with valid signatures.
    public var active: [Approval] {
        reloadIfChanged()
        let t = now()
        return approvals.filter { $0.expiresAt > t && isValid($0) }
    }

    /// Unexpired entries whose signatures don't verify.
    public var rejected: [Approval] {
        reloadIfChanged()
        let t = now()
        return approvals.filter { $0.expiresAt > t && !isValid($0) }
    }

    public func isApproved(_ key: ApprovalKey) -> Bool {
        reloadIfChanged()
        let t = now()
        return approvals.contains { $0.key == key && $0.expiresAt > t && isValid($0) }
    }

    /// `sign` receives the payload to sign; see `Approval.signedPayload`. `ttl` overrides the
    /// store's default lifetime.
    public func approve(_ key: ApprovalKey, sessionLabel: String?, itemLabel: String? = nil, ttl: TimeInterval? = nil,
                        sign: (Data) throws -> Data) throws {
        reloadIfChanged()
        // Whole seconds, so the payload re-derived from the ISO 8601 file matches.
        let t = Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down))
        let expires = t.addingTimeInterval(ttl ?? self.ttl)
        let signature = try sign(Approval.payload(key: key, approvedAt: t, expiresAt: expires))
        approvals.removeAll { $0.key == key || $0.expiresAt <= t }
        approvals.append(Approval(key: key, approvedAt: t, expiresAt: expires, sessionLabel: sessionLabel,
                                  itemLabel: itemLabel, signature: signature))
        try save()
    }

    /// Records an approval given on a paired phone. Its times are the ones the phone's grant
    /// committed to (see `DeviceProofCheck`), so they're taken as given rather than from now.
    public func approve(_ key: ApprovalKey, sessionLabel: String?, itemLabel: String?, approvedAt: Date, expiresAt: Date,
                        proof: DeviceProof) throws {
        reloadIfChanged()
        let t = now()
        approvals.removeAll { $0.key == key || $0.expiresAt <= t }
        approvals.append(Approval(key: key, approvedAt: approvedAt, expiresAt: expiresAt, sessionLabel: sessionLabel,
                                  itemLabel: itemLabel, signature: nil, deviceProof: proof))
        try save()
    }

    /// Re-signs an existing approval with a new expiry, keeping when it was first approved and
    /// its labels. The new signature is the Mac's, so a phone's proof is dropped. Returns false if there is no such active approval.
    @discardableResult
    public func changeExpiry(_ key: ApprovalKey, to expiresAt: Date, sign: (Data) throws -> Data) throws -> Bool {
        reloadIfChanged()
        guard let existing = active.first(where: { $0.key == key }) else { return false }
        let expires = Date(timeIntervalSince1970: expiresAt.timeIntervalSince1970.rounded(.down))
        let signature = try sign(Approval.payload(key: key, approvedAt: existing.approvedAt, expiresAt: expires))
        approvals.removeAll { $0.key == key }
        approvals.append(Approval(key: key, approvedAt: existing.approvedAt, expiresAt: expires,
                                  sessionLabel: existing.sessionLabel, itemLabel: existing.itemLabel, signature: signature))
        try save()
        return true
    }

    /// Replaces an approval's display label (unsigned, so no signature is involved).
    public func setItemLabel(_ key: ApprovalKey, to label: String) throws {
        reloadIfChanged()
        guard let i = approvals.firstIndex(where: { $0.key == key }) else { return }
        let a = approvals[i]
        approvals[i] = Approval(key: a.key, approvedAt: a.approvedAt, expiresAt: a.expiresAt, sessionLabel: a.sessionLabel,
                                itemLabel: label, signature: a.signature, deviceProof: a.deviceProof)
        try save()
    }

    /// Stands in for "never expires": far enough out, and still a valid ISO 8601 date.
    public static let forever = Date(timeIntervalSince1970: 4_102_444_800)  // 2100-01-01

    /// Removes approvals matching `predicate`; returns how many were removed.
    @discardableResult
    public func revoke(where predicate: (Approval) -> Bool) throws -> Int {
        reloadIfChanged()
        let before = approvals.count
        approvals.removeAll(where: predicate)
        try save()
        return before - approvals.count
    }

    private func save() throws {
        let t = now()
        approvals.removeAll { $0.expiresAt <= t }
        let data = try Self.encoder.encode(approvals)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        loadedModification = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
