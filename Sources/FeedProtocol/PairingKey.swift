import CryptoKit
import Foundation

/// The key one Mac and one phone share for as long as they're paired. Every feed record
/// between them is sealed with it (`SealedRecord`), so only that pair can read a record or
/// write one the other accepts: whoever else can write to the zone, or holds the iCloud
/// credentials, can neither read requests nor post a fake one for the phone to sign.
///
/// The Mac keeps the secret in 1Password, which generates it, and hands it to the phone
/// during pairing (`PairingHandshake`). Unpairing deletes it on both sides.
public struct PairingKey {
    public let key: SymmetricKey

    /// `secret` is the generated password as 1Password stores it.
    public init(secret: Data) {
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), info: Data("opProxy pairing key v1".utf8),
                                     outputByteCount: 32)
    }

    /// Names the pairing without revealing the key: 32 hex digits.
    public var id: String {
        hex(Data(HMAC<SHA256>.authenticationCode(for: Data("opProxy pairing id".utf8), using: key)).prefix(16))
    }
}

/// One feed record's payload, sealed with the pairing key (ChaCha20-Poly1305). The record's
/// type and name and the sender are authenticated alongside it, so a sealed payload can't
/// be moved to another record or reflected back as the other side's. It also carries when
/// it was sealed, so a reader can refuse stale copies written back later.
public enum SealedRecord {
    public enum Sender: String {
        case mac, phone
    }

    public enum Failure: Error, Equatable {
        case unreadable
        case stale(sealedAt: Date)
    }

    /// How far a sender's clock may run ahead of the reader's.
    public static let clockSkew: TimeInterval = 300

    public static func seal(_ body: Data, with pairing: PairingKey, recordType: String, recordName: String,
                            from sender: Sender, at date: Date = Date()) throws -> Data {
        var ms = UInt64(max(0, date.timeIntervalSince1970 * 1000)).bigEndian
        let plain = Data(bytes: &ms, count: 8) + body
        return try ChaChaPoly.seal(plain, using: pairing.key,
                                   authenticating: context(recordType, recordName, sender)).combined
    }

    /// The body, if this pairing sealed it for exactly this record and sender. With `maxAge`,
    /// anything sealed longer ago than that is refused.
    public static func open(_ sealed: Data, with pairing: PairingKey, recordType: String, recordName: String,
                            from sender: Sender, maxAge: TimeInterval? = nil, now: Date = Date()) throws -> Data {
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed),
              let plain = try? ChaChaPoly.open(box, using: pairing.key, authenticating: context(recordType, recordName, sender)),
              plain.count >= 8 else { throw Failure.unreadable }
        let ms = plain.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let sealedAt = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        if let maxAge, sealedAt < now - maxAge || sealedAt > now + clockSkew {
            throw Failure.stale(sealedAt: sealedAt)
        }
        return plain.dropFirst(8)
    }

    private static func context(_ recordType: String, _ recordName: String, _ sender: Sender) -> Data {
        Data(["opProxy sealed record v1", recordType, recordName, sender.rawValue].joined(separator: "\u{0}").utf8)
    }
}

/// A feed record field in a sealed zone (`CloudFeed.sealedZonePrefix`): the base64 of a
/// `SealedRecord` over the field's usual JSON string, bound to the record type, the field
/// and the record's name. Stored in the same encrypted CloudKit fields as before.
public enum SealedField {
    public static func seal(_ text: String, with pairing: PairingKey, recordType: String, field: String, recordName: String,
                            from sender: SealedRecord.Sender, at date: Date = Date()) throws -> String {
        try SealedRecord.seal(Data(text.utf8), with: pairing, recordType: recordType + "." + field, recordName: recordName,
                              from: sender, at: date).base64EncodedString()
    }

    public static func open(_ value: String, with pairing: PairingKey, recordType: String, field: String, recordName: String,
                            from sender: SealedRecord.Sender, maxAge: TimeInterval? = nil, now: Date = Date()) throws -> String {
        guard let sealed = Data(base64Encoded: value) else { throw SealedRecord.Failure.unreadable }
        let plain = try SealedRecord.open(sealed, with: pairing, recordType: recordType + "." + field, recordName: recordName,
                                          from: sender, maxAge: maxAge, now: now)
        guard let text = String(data: plain, encoding: .utf8) else { throw SealedRecord.Failure.unreadable }
        return text
    }
}

/// Getting the pairing secret from the Mac to the phone. The Mac's QR code carries a fresh
/// X25519 public key; the phone answers with its own, signed by its Secure Enclave key, the
/// one whose fingerprint you compare before confirming with Touch ID. The Mac seals the
/// secret to the key they agree on, so only that phone can open it, and only after you
/// confirmed it.
public enum PairingHandshake {
    /// Extra fields of the phone's `pair` message (base64): its X25519 key, and its device
    /// key's signature over `phoneStatement`.
    public static let agreementKeyField = "agreementKey"
    public static let agreementSignatureField = "agreementSignature"
    /// The Mac's `pair-result` field (base64): the pairing secret, sealed for the phone.
    public static let sealedSecretField = "sealedSecret"

    /// What the phone signs with its device key: its agreement key, bound to this Mac's
    /// offer, so it can't be lifted into another pairing.
    public static func phoneStatement(phoneAgreementKey: Data, macAgreementKey: Data, macID: String) -> Data {
        Data("opProxy pairing handshake v1\u{0}".utf8) + macAgreementKey + phoneAgreementKey + Data(macID.utf8)
    }

    /// Mac side: checks the phone signed `phoneAgreementKey` for this offer with the device
    /// key being paired, then seals the secret for it.
    public static func sealSecret(_ secret: Data, macKey: Curve25519.KeyAgreement.PrivateKey, phoneAgreementKey: Data,
                                  phoneSignature: Data, phoneDeviceKey: Data, macID: String) throws -> Data {
        let macPublic = macKey.publicKey.rawRepresentation
        guard DeviceKey.verify(phoneStatement(phoneAgreementKey: phoneAgreementKey, macAgreementKey: macPublic, macID: macID),
                               signature: phoneSignature, rawPublicKey: phoneDeviceKey) else { throw Failure.badSignature }
        let key = try wrapKey(mine: macKey, theirs: phoneAgreementKey, macPublic: macPublic, phonePublic: phoneAgreementKey,
                              phoneDeviceKey: phoneDeviceKey, macID: macID)
        return try ChaChaPoly.seal(secret, using: key).combined
    }

    /// Phone side: opens the secret the Mac sealed for it.
    public static func openSecret(_ sealed: Data, phoneKey: Curve25519.KeyAgreement.PrivateKey, macAgreementKey: Data,
                                  phoneDeviceKey: Data, macID: String) throws -> Data {
        let key = try wrapKey(mine: phoneKey, theirs: macAgreementKey, macPublic: macAgreementKey,
                              phonePublic: phoneKey.publicKey.rawRepresentation, phoneDeviceKey: phoneDeviceKey, macID: macID)
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed), let secret = try? ChaChaPoly.open(box, using: key)
        else { throw Failure.unreadable }
        return secret
    }

    public enum Failure: Error, Equatable {
        case badSignature, unreadable
    }

    private static func wrapKey(mine: Curve25519.KeyAgreement.PrivateKey, theirs: Data, macPublic: Data, phonePublic: Data,
                                phoneDeviceKey: Data, macID: String) throws -> SymmetricKey {
        let shared = try mine.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirs))
        let transcript = Data("opProxy pairing wrap v1".utf8) + macPublic + phonePublic + phoneDeviceKey + Data(macID.utf8)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: transcript, outputByteCount: 32)
    }
}
