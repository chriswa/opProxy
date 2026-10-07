import CryptoKit
import Foundation
import FeedProtocol
import Security

/// The phone's signing key: a P-256 key in the Secure Enclave, usable only while the phone is
/// unlocked and never leaving it. Its blob is kept in the keychain. The simulator has no
/// Secure Enclave, so there it's a software key.
enum PhoneKey {
    private static let account = "opProxy.phoneKey"

    static var publicKey: Data { (try? load())?.publicKey ?? Data() }
    static var keyId: String { DeviceKey.keyId(rawPublicKey: publicKey) }
    static var fingerprint: String { DeviceKey.fingerprint(keyId: keyId) }

    static func sign(_ data: Data) throws -> Data { try load().sign(data) }

    private struct Key {
        let publicKey: Data
        let sign: (Data) throws -> Data
    }

    private static func load() throws -> Key {
        if let blob = read() { return try key(from: blob) }
        let blob: Data
        #if targetEnvironment(simulator)
        blob = P256.Signing.PrivateKey().rawRepresentation
        #else
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           .privateKeyUsage, &error)
        else { throw error!.takeRetainedValue() as Error }
        blob = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access).dataRepresentation
        #endif
        write(blob)
        return try key(from: blob)
    }

    private static func key(from blob: Data) throws -> Key {
        #if targetEnvironment(simulator)
        let key = try P256.Signing.PrivateKey(rawRepresentation: blob)
        #else
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
        #endif
        return Key(publicKey: key.publicKey.rawRepresentation) { try key.signature(for: $0).derRepresentation }
    }

    private static func read() -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true]
        var out: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    private static func write(_ blob: Data) {
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                   kSecValueData as String: blob,
                                   kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        SecItemAdd(item as CFDictionary, nil)
    }
}
