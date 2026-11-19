import CryptoKit
import Foundation
import OpProxyCore

/// Signs approvals so a forged or edited approvals.json entry doesn't verify.
protocol ApprovalSigner {
    func sign(_ payload: Data) throws -> Data
    func verify(_ payload: Data, signature: Data) -> Bool
}

/// For builds without the provisioning profile: a Secure Enclave P-256 key that needs user
/// presence for every signature. Its blob is a file any process running as you can load, so
/// the presence check is what keeps an agent from signing with it: each lasting approval,
/// pairing or change from the menu asks for Touch ID in the system's own sheet. The public
/// key it verifies against is compiled into this binary (ApprovalKeyPin.swift, written by
/// install.sh), not read from disk, so swapping in another key blob makes approvals fail
/// rather than letting forged ones through.
struct EnclaveSigner: ApprovalSigner {
    let blob: URL
    let publicKey: P256.Signing.PublicKey

    static func accessControl() -> SecAccessControl {
        SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                        [.privateKeyUsage, .userPresence], nil)!
    }

    /// The key compiled into this build by install.sh, if any.
    static var pinnedPublicKey: P256.Signing.PublicKey? {
        pinnedApprovalPublicKey.flatMap { Data(base64Encoded: $0) }.flatMap { try? P256.Signing.PublicKey(rawRepresentation: $0) }
    }

    /// The pinned signer, or nil when this build has no pinned key.
    static func pinned(blob: URL) -> EnclaveSigner? {
        pinnedPublicKey.map { EnclaveSigner(blob: blob, publicKey: $0) }
    }

    /// Loads the key at `blob`, creating it first if needed; returns the raw public key.
    /// Neither step needs Touch ID; only signing does.
    static func publicKey(creatingAt blob: URL) throws -> Data {
        if let data = try? Data(contentsOf: blob) {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data).publicKey.rawRepresentation
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl())
        try key.dataRepresentation.write(to: blob, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blob.path)
        return key.publicKey.rawRepresentation
    }

    func sign(_ payload: Data) throws -> Data {
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: Data(contentsOf: blob))
        return try key.signature(for: payload).derRepresentation
    }

    func verify(_ payload: Data, signature: Data) -> Bool {
        guard let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return publicKey.isValidSignature(sig, for: payload)
    }
}

#if OPPROXY_TESTING
/// Test builds: a software key kept in the (test) state dir.
struct SoftwareSigner: ApprovalSigner {
    let key: P256.Signing.PrivateKey

    init(stateDir: URL) {
        let file = stateDir.appendingPathComponent("test-approval-key")
        if let raw = try? Data(contentsOf: file), let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            self.key = key
        } else {
            key = P256.Signing.PrivateKey()
            try? key.rawRepresentation.write(to: file)
        }
    }

    func sign(_ payload: Data) throws -> Data {
        try key.signature(for: payload).derRepresentation
    }

    func verify(_ payload: Data, signature: Data) -> Bool {
        guard let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return key.publicKey.isValidSignature(sig, for: payload)
    }
}
#endif

/// A Secure Enclave P-256 key kept in opProxy's own keychain access group, which only apps
/// signed by its team can use: an agent can neither use it, swap it, nor plant one of its
/// own before opProxy first creates it. Signing needs no Touch ID, so the dialog's Allow
/// button signs. Builds signed with the provisioning profile use this; others fall back to
/// `EnclaveSigner`.
struct KeychainSigner: ApprovalSigner {
    static let tag = Data("com.chriswa.opproxy.approval-key.2".utf8)
    /// The key before approvals moved off Touch ID: it needs user presence for every
    /// signature, so it only verifies now.
    static let touchIDTag = Data("com.chriswa.opproxy.approval-key".utf8)
    static let accessGroup = "7H2524M5TN.com.chriswa.opproxy"

    let publicKey: P256.Signing.PublicKey
    /// Keys this Mac signed with before: the Touch ID key, and the key it pinned before the
    /// keychain held one. Approvals and paired phones they signed still verify.
    let legacy: [P256.Signing.PublicKey]

    /// Whether this build may use the access group: it needs the provisioning profile's entitlements.
    static var available: Bool { Entitlement.strings("keychain-access-groups").contains(accessGroup) }

    /// The key, made on first use.
    static func loadOrCreate() throws -> KeychainSigner {
        let key = try find(tag) ?? create()
        let legacy = [try? find(touchIDTag)].compactMap { $0.flatMap(publicKey(of:)) } + [EnclaveSigner.pinnedPublicKey].compactMap { $0 }
        guard let publicKey = publicKey(of: key) else { throw SignerError("couldn't read the approval key's public half") }
        return KeychainSigner(publicKey: publicKey, legacy: legacy)
    }

    private static func publicKey(of key: SecKey) -> P256.Signing.PublicKey? {
        SecKeyCopyPublicKey(key).flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? }
            .flatMap { try? P256.Signing.PublicKey(x963Representation: $0) }
    }

    func sign(_ payload: Data) throws -> Data {
        guard let key = try Self.find(Self.tag) else { throw SignerError("the approval key is missing from the keychain") }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, payload as CFData, &error) as Data? else {
            throw error!.takeRetainedValue() as Error
        }
        return signature
    }

    func verify(_ payload: Data, signature: Data) -> Bool {
        guard let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return ([publicKey] + legacy).contains { $0.isValidSignature(sig, for: payload) }
    }

    private static func find(_ tag: Data) throws -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnRef as String: true,
        ]
        var out: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &out) {
        case errSecSuccess: return (out as! SecKey)
        case errSecItemNotFound: return nil
        case let status: throw SignerError("keychain lookup failed (\(status))")
        }
    }

    private static func create() throws -> SecKey {
        let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage], nil)!
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain as String: true,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessGroup as String: accessGroup,
                kSecAttrAccessControl as String: access,
            ] as [String: Any],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else { throw error!.takeRetainedValue() as Error }
        return key
    }
}

struct SignerError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The signer this build uses, or nil if none is available (approvals then never persist).
func makeApprovalSigner(paths: Paths, log: Log? = nil) -> ApprovalSigner? {
    #if OPPROXY_TESTING
    return SoftwareSigner(stateDir: paths.stateDir)
    #else
    if KeychainSigner.available {
        do { return try KeychainSigner.loadOrCreate() } catch { log?.write("approval key: \(error)") }
    }
    return EnclaveSigner.pinned(blob: paths.approvalKey)
    #endif
}

/// A store that only honours entries signed by `signer`, or approved on a phone in `devices`.
func makeApprovalStore(paths: Paths, signer: ApprovalSigner?, devices: PairedDeviceStore) -> ApprovalStore {
    ApprovalStore(url: paths.approvals, verify: { payload, signature in
        signer?.verify(payload, signature: signature) ?? false
    }, verifyDevice: { DeviceProofCheck.verify($0, device: devices.device(keyId:)) })
}

/// Paired phones, honoured only when `signer` signed their entry.
func makePairedDeviceStore(paths: Paths, signer: ApprovalSigner?) -> PairedDeviceStore {
    PairedDeviceStore(url: paths.pairedDevices) { payload, signature in
        signer?.verify(payload, signature: signature) ?? false
    }
}
