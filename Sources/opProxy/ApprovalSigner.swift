import CryptoKit
import Foundation
import LocalAuthentication
import OpProxyCore

/// Signs approvals so a forged or edited approvals.json entry doesn't verify.
protocol ApprovalSigner {
    /// `context` is the LAContext the approval dialog's Touch ID already evaluated.
    func sign(_ payload: Data, context: LAContext?) throws -> Data
    func verify(_ payload: Data, signature: Data) -> Bool
}

/// For builds without the provisioning profile: a Secure Enclave P-256 key that needs user
/// presence for every signature, so only a Touch ID approval can produce one. The public key
/// it verifies against is compiled into this binary (ApprovalKeyPin.swift, written by
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

    func sign(_ payload: Data, context: LAContext?) throws -> Data {
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: Data(contentsOf: blob),
                                                            authenticationContext: context)
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

    func sign(_ payload: Data, context: LAContext?) throws -> Data {
        try key.signature(for: payload).derRepresentation
    }

    func verify(_ payload: Data, signature: Data) -> Bool {
        guard let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return key.publicKey.isValidSignature(sig, for: payload)
    }
}
#endif

/// A Secure Enclave P-256 key kept in opProxy's own keychain access group, which only apps
/// signed by its team can use: an agent can neither read it, swap it, nor plant one of its own
/// before opProxy first creates it. Every signature needs user presence, so only a Touch ID
/// approval can produce one. Builds signed with the provisioning profile use this; others
/// fall back to `EnclaveSigner`.
struct KeychainSigner: ApprovalSigner {
    static let tag = Data("com.chriswa.opproxy.approval-key".utf8)
    static let accessGroup = "7H2524M5TN.com.chriswa.opproxy"

    let publicKey: P256.Signing.PublicKey
    /// The key this Mac pinned before the keychain held one, if this build has it: approvals
    /// and paired phones it signed still verify.
    let legacy: P256.Signing.PublicKey?

    /// Whether this build may use the access group: it needs the provisioning profile's entitlements.
    static var available: Bool { Entitlement.strings("keychain-access-groups").contains(accessGroup) }

    /// The key, made on first use. Neither step needs Touch ID; only signing does.
    static func loadOrCreate() throws -> KeychainSigner {
        let key = try find(context: nil) ?? create()
        guard let external = SecKeyCopyPublicKey(key).flatMap({ SecKeyCopyExternalRepresentation($0, nil) as Data? }) else {
            throw SignerError("couldn't read the approval key's public half")
        }
        return KeychainSigner(publicKey: try P256.Signing.PublicKey(x963Representation: external),
                              legacy: EnclaveSigner.pinnedPublicKey)
    }

    func sign(_ payload: Data, context: LAContext?) throws -> Data {
        guard let key = try Self.find(context: context) else { throw SignerError("the approval key is missing from the keychain") }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, payload as CFData, &error) as Data? else {
            throw error!.takeRetainedValue() as Error
        }
        return signature
    }

    func verify(_ payload: Data, signature: Data) -> Bool {
        guard let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return publicKey.isValidSignature(sig, for: payload) || legacy?.isValidSignature(sig, for: payload) == true
    }

    private static func find(context: LAContext?) throws -> SecKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnRef as String: true,
        ]
        if let context { query[kSecUseAuthenticationContext as String] = context }
        var out: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &out) {
        case errSecSuccess: return (out as! SecKey)
        case errSecItemNotFound: return nil
        case let status: throw SignerError("keychain lookup failed (\(status))")
        }
    }

    private static func create() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain as String: true,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessGroup as String: accessGroup,
                kSecAttrAccessControl as String: EnclaveSigner.accessControl(),
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
