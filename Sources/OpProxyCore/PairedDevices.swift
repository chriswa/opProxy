import Foundation

/// A phone allowed to answer approvals from the approval feed.
public struct PairedDevice: Codable, Equatable {
    public let keyId: String
    public let name: String
    /// Raw 64-byte P-256 public key (X‖Y).
    public let publicKey: Data
    public let pairedAt: Date
    /// Over `signedPayload`, made with the Touch ID-gated approval key when it was paired.
    public let signature: Data?

    public var fingerprint: String { DeviceKey.fingerprint(keyId: keyId) }

    /// Canonical bytes covering the key and its name.
    public var signedPayload: Data { Self.payload(keyId: keyId, name: name, publicKey: publicKey, pairedAt: pairedAt) }

    static func payload(keyId: String, name: String, publicKey: Data, pairedAt: Date) -> Data {
        struct Signed: Encodable {
            let version = 1
            let purpose = "paired-device"
            let keyId: String
            let name: String
            let publicKey: Data
            let pairedAt: Date
        }
        return try! PairedDeviceStore.encoder.encode(Signed(keyId: keyId, name: name, publicKey: publicKey, pairedAt: pairedAt))
    }
}

/// Paired phones, persisted as JSON. Like approvals, each entry is signed with the approval
/// key, so an agent can't pair a key of its own by editing the file: entries that don't
/// verify, or whose key ID isn't their key's, are ignored. Thread-safe: the feed, the
/// daemon's approval checks and the menu all read it.
public final class PairedDeviceStore {
    private let url: URL
    private let now: () -> Date
    private let verify: (_ payload: Data, _ signature: Data) -> Bool
    private let lock = NSLock()
    private var entries: [PairedDevice] = []
    private var loadedModification: Date?

    public init(url: URL, now: @escaping () -> Date = Date.init, verify: @escaping (_ payload: Data, _ signature: Data) -> Bool) {
        self.url = url
        self.now = now
        self.verify = verify
    }

    private func isValid(_ d: PairedDevice) -> Bool {
        guard let signature = d.signature, d.publicKey.count == 64,
              d.keyId == DeviceKey.keyId(rawPublicKey: d.publicKey) else { return false }
        return verify(d.signedPayload, signature)
    }

    /// Picks up `opProxy unpair` edits made by another process. Call with the lock held.
    private func reloadIfChanged() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard modified != loadedModification else { return }
        loadedModification = modified
        let data = try? Data(contentsOf: url)
        entries = data.flatMap { try? Self.decoder.decode([PairedDevice].self, from: $0) } ?? []
    }

    /// Verified devices, oldest first.
    public var devices: [PairedDevice] {
        lock.withLock {
            reloadIfChanged()
            return entries.filter(isValid)
        }
    }

    /// Entries that don't verify.
    public var rejected: [PairedDevice] {
        lock.withLock {
            reloadIfChanged()
            return entries.filter { !isValid($0) }
        }
    }

    public func device(keyId: String) -> PairedDevice? {
        lock.withLock {
            reloadIfChanged()
            return entries.first { $0.keyId == keyId && isValid($0) }
        }
    }

    /// `sign` receives the payload to sign; see `PairedDevice.signedPayload`. Re-pairing a key
    /// replaces its entry.
    @discardableResult
    public func pair(publicKey: Data, name: String, sign: (Data) throws -> Data) throws -> PairedDevice {
        let keyId = DeviceKey.keyId(rawPublicKey: publicKey)
        // Whole seconds, so the payload re-derived from the ISO 8601 file matches.
        let t = Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down))
        let signature = try sign(PairedDevice.payload(keyId: keyId, name: name, publicKey: publicKey, pairedAt: t))
        let device = PairedDevice(keyId: keyId, name: name, publicKey: publicKey, pairedAt: t, signature: signature)
        try lock.withLock {
            reloadIfChanged()
            entries.removeAll { $0.keyId == keyId }
            entries.append(device)
            try save()
        }
        return device
    }

    /// Removes devices matching `predicate`; returns how many were removed.
    @discardableResult
    public func unpair(where predicate: (PairedDevice) -> Bool) throws -> Int {
        try lock.withLock {
            reloadIfChanged()
            let before = entries.count
            entries.removeAll(where: predicate)
            try save()
            return before - entries.count
        }
    }

    private func save() throws {
        try Self.encoder.encode(entries).write(to: url, options: .atomic)
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
