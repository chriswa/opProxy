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

/// A Secure Enclave P-256 key that needs user presence for every signature, so only a Touch
/// ID approval can produce one. The public key it verifies against is compiled into this
/// binary (ApprovalKeyPin.swift, written by install.sh), not read from disk, so swapping
/// in another key blob makes approvals fail rather than letting forged ones through.
struct EnclaveSigner: ApprovalSigner {
    let blob: URL
    let publicKey: P256.Signing.PublicKey

    static func accessControl() -> SecAccessControl {
        SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                        [.privateKeyUsage, .userPresence], nil)!
    }

    /// The pinned signer, or nil when this build has no pinned key.
    static func pinned(blob: URL) -> EnclaveSigner? {
        guard let pin = pinnedApprovalPublicKey, let raw = Data(base64Encoded: pin),
              let key = try? P256.Signing.PublicKey(rawRepresentation: raw) else { return nil }
        return EnclaveSigner(blob: blob, publicKey: key)
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

/// The signer this build uses, or nil if none is available (approvals then never persist).
func makeApprovalSigner(paths: Paths) -> ApprovalSigner? {
    #if OPPROXY_TESTING
    return SoftwareSigner(stateDir: paths.stateDir)
    #else
    return EnclaveSigner.pinned(blob: paths.approvalKey)
    #endif
}

/// A store that only honours entries signed by `signer`.
func makeApprovalStore(paths: Paths, signer: ApprovalSigner?) -> ApprovalStore {
    ApprovalStore(url: paths.approvals) { payload, signature in
        signer?.verify(payload, signature: signature) ?? false
    }
}
