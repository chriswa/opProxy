import Foundation

/// Which agents an approval covers.
public enum ApprovalAudience: Codable, Hashable {
    /// One agent session, by the ID it claims. A resumed session keeps its ID, so it's
    /// covered too.
    case session(agent: AgentKind, sessionId: String)
    /// One agent process (`SessionIdentity.agentInstance`), for an agent that doesn't name
    /// its session.
    case process(agent: AgentKind, instance: String)
    /// Every genuine agent, of any kind, including ones started later.
    case allAgents

    public var sessionId: String? {
        if case .session(_, let id) = self { return id }
        return nil
    }

    /// "claude:<session ID>", for logs.
    public var logName: String {
        switch self {
        case .session(let agent, let id): return "\(agent.rawValue):\(id)"
        case .process(let agent, _): return "\(agent.rawValue):unknown"
        case .allAgents: return "all-agents"
        }
    }
}

/// One 1Password item, by ID.
public struct ItemRef: Codable, Hashable {
    /// `--account` or `OP_ACCOUNT` as the request gave it; nil for the default account.
    public let account: String?
    public let vaultId: String
    public let itemId: String

    public init(account: String?, vaultId: String, itemId: String) {
        self.account = account
        self.vaultId = vaultId
        self.itemId = itemId
    }
}

/// What an approval covers: every read of one item, for `audience`.
public struct ApprovalKey: Codable, Hashable {
    public let audience: ApprovalAudience
    public let item: ItemRef

    public init(audience: ApprovalAudience, item: ItemRef) {
        self.audience = audience
        self.item = item
    }

    /// The same item for another audience.
    public func reaching(_ audience: ApprovalAudience) -> ApprovalKey {
        ApprovalKey(audience: audience, item: item)
    }

    /// Whether an approval under this key lets `request` (a requester's own key) run.
    public func covers(_ request: ApprovalKey) -> Bool {
        item == request.item && (audience == .allAgents || audience == request.audience)
    }
}

/// How long a lasting approval runs.
public enum ApprovalLifetime: String, CaseIterable {
    case day, forever

    public var label: String {
        switch self {
        case .day: return "1 Day"
        case .forever: return "Forever"
        }
    }

    public func expiry(from approvedAt: Date) -> Date {
        switch self {
        case .day: return approvedAt.addingTimeInterval(24 * 60 * 60)
        case .forever: return ApprovalStore.forever
        }
    }
}

public struct Approval: Codable, Equatable {
    public let key: ApprovalKey
    public let approvedAt: Date
    public let expiresAt: Date
    /// Spaceterm title at approval time, for `opProxy list` and the menu. Display only, so unsigned.
    public let sessionLabel: String?
    /// The requester whose dialog granted an all-agents approval, so the menu can narrow it
    /// back to them. Display only, so unsigned: narrowing never grants more than the entry did.
    public let grantedTo: ApprovalAudience?
    /// The item's title and vault name as the dialog showed them. Display only, so unsigned.
    public let itemLabel: String?
    public let vaultLabel: String?
    /// Signature over `signedPayload`, made with the Touch ID-gated approval key.
    public let signature: Data?
    /// For approvals given on a paired phone, which can't use the Mac's approval key: the
    /// phone's signed statement, whose challenge commits to `signedPayload`.
    public let deviceProof: DeviceProof?

    init(key: ApprovalKey, approvedAt: Date, expiresAt: Date, sessionLabel: String?, grantedTo: ApprovalAudience?,
         itemLabel: String?, vaultLabel: String?, signature: Data?, deviceProof: DeviceProof? = nil) {
        self.key = key
        self.approvedAt = approvedAt
        self.expiresAt = expiresAt
        self.sessionLabel = sessionLabel
        self.grantedTo = grantedTo
        self.itemLabel = itemLabel
        self.vaultLabel = vaultLabel
        self.signature = signature
        self.deviceProof = deviceProof
    }

    /// "Private / Chat webhook", or the item ID if no names were recorded.
    public var label: String {
        itemLabel.map { t in vaultLabel.map { "\($0) / \(t)" } ?? t } ?? key.item.itemId
    }

    /// Canonical bytes covering everything that grants access.
    public var signedPayload: Data {
        Self.payload(key: key, approvedAt: approvedAt, expiresAt: expiresAt)
    }

    /// `approvedAt` and `expiresAt` must be whole seconds, or the payload re-derived from the
    /// ISO 8601 file won't match.
    public static func payload(key: ApprovalKey, approvedAt: Date, expiresAt: Date) -> Data {
        struct Signed: Encodable {
            let version = 3
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
    private let url: URL
    private let now: () -> Date
    private let verify: (_ payload: Data, _ signature: Data) -> Bool
    private let verifyDevice: (Approval) -> Bool
    private var approvals: [Approval] = []
    private var loadedModification: Date?

    public init(url: URL, now: @escaping () -> Date = Date.init,
                verify: @escaping (_ payload: Data, _ signature: Data) -> Bool,
                verifyDevice: @escaping (Approval) -> Bool = { _ in false }) {
        self.url = url
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

    /// Whether `request`, a requester's own key, may run: approved for its audience or for
    /// all agents.
    public func isApproved(_ request: ApprovalKey) -> Bool {
        reloadIfChanged()
        let t = now()
        return approvals.contains { $0.key.covers(request) && $0.expiresAt > t && isValid($0) }
    }

    /// Approves `key` from now for `lifetime`. `sign` receives the payload to sign; see
    /// `Approval.signedPayload`.
    public func approve(_ key: ApprovalKey, lifetime: ApprovalLifetime, sessionLabel: String?,
                        grantedTo: ApprovalAudience? = nil, itemLabel: String? = nil, vaultLabel: String? = nil,
                        sign: (Data) throws -> Data) throws {
        reloadIfChanged()
        // Whole seconds, so the payload re-derived from the ISO 8601 file matches.
        let t = Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down))
        let expires = lifetime.expiry(from: t)
        let signature = try sign(Approval.payload(key: key, approvedAt: t, expiresAt: expires))
        store(Approval(key: key, approvedAt: t, expiresAt: expires, sessionLabel: sessionLabel, grantedTo: grantedTo,
                       itemLabel: itemLabel, vaultLabel: vaultLabel, signature: signature))
        try save()
    }

    /// Records an approval given on a paired phone. Its times are the ones the phone's grant
    /// committed to (see `DeviceProofCheck`), so they're taken as given rather than from now.
    public func approve(_ key: ApprovalKey, sessionLabel: String?, grantedTo: ApprovalAudience? = nil, itemLabel: String?,
                        vaultLabel: String?, approvedAt: Date, expiresAt: Date, proof: DeviceProof) throws {
        reloadIfChanged()
        store(Approval(key: key, approvedAt: approvedAt, expiresAt: expiresAt, sessionLabel: sessionLabel,
                       grantedTo: grantedTo, itemLabel: itemLabel, vaultLabel: vaultLabel, signature: nil, deviceProof: proof))
        try save()
    }

    /// Replaces any entry for the same key, and drops narrower entries an all-agents one covers.
    private func store(_ approval: Approval) {
        approvals.removeAll { approval.key.covers($0.key) && $0.expiresAt <= approval.expiresAt }
        approvals.removeAll { $0.key == approval.key }
        approvals.append(approval)
    }

    /// Re-signs an existing approval with a new audience and/or expiry, keeping when it was
    /// first approved and its labels. The new signature is the Mac's, so a phone's proof is
    /// dropped. Returns false if there is no such active approval.
    @discardableResult
    public func amend(_ key: ApprovalKey, audience: ApprovalAudience? = nil, expiresAt: Date? = nil,
                      sign: (Data) throws -> Data) throws -> Bool {
        reloadIfChanged()
        guard let existing = active.first(where: { $0.key == key }) else { return false }
        let newKey = audience.map(key.reaching) ?? key
        let expires = Date(timeIntervalSince1970: (expiresAt ?? existing.expiresAt).timeIntervalSince1970.rounded(.down))
        let signature = try sign(Approval.payload(key: newKey, approvedAt: existing.approvedAt, expiresAt: expires))
        approvals.removeAll { $0.key == key }
        store(Approval(key: newKey, approvedAt: existing.approvedAt, expiresAt: expires, sessionLabel: existing.sessionLabel,
                       grantedTo: newKey.audience == .allAgents ? existing.grantedTo ?? key.audience : nil,
                       itemLabel: existing.itemLabel, vaultLabel: existing.vaultLabel, signature: signature))
        try save()
        return true
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
