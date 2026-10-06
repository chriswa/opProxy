import CryptoKit
import Foundation

/// A paired phone's signed answer to one approval feed item, kept with an approval that was
/// given on the phone. It's the phone's own statement, verbatim (APPROVAL_FEED.md).
public struct DeviceProof: Codable, Equatable {
    public let keyId: String
    /// The exact string the phone signed.
    public let statement: String
    /// ECDSA P-256 over SHA-256 of `statement`'s UTF-8 bytes, DER.
    public let signature: Data

    public init(keyId: String, statement: String, signature: Data) {
        self.keyId = keyId
        self.statement = statement
        self.signature = signature
    }
}

/// What a phone signs to answer an item.
public struct ApprovalStatement: Codable, Equatable {
    public let v: Int
    public let provider: String
    public let id: String
    public let revision: Int
    /// The item's challenge, verbatim.
    public let challenge: String
    public let documentSha256: String
    public let action: String
    /// Picker ID → option ID.
    public let picks: [String: String]
    public let keyId: String
    public let signedAt: Double

    public init(id: String, revision: Int, challenge: String, documentSha256: String, action: String,
                picks: [String: String], keyId: String, signedAt: Double) {
        v = 1
        provider = "opProxy"
        (self.id, self.revision, self.challenge, self.documentSha256) = (id, revision, challenge, documentSha256)
        (self.action, self.picks, self.keyId, self.signedAt) = (action, picks, keyId, signedAt)
    }

    public static func parse(_ statement: String) -> ApprovalStatement? {
        try? JSONDecoder().decode(ApprovalStatement.self, from: Data(statement.utf8))
    }
}

/// opProxy's item challenge. Besides a nonce, it commits in advance to the exact approval
/// each lasting option would store, so a phone's signature over it can stand in for the
/// Mac's approval key: the stored entry must match the grant for the option the phone picked.
public struct ApprovalChallenge: Codable, Equatable {
    public let nonce: String
    /// The picker whose option chooses the grant.
    public let picker: String
    /// Option ID → lowercase hex SHA-256 of the `Approval.signedPayload` it grants. Options
    /// that store nothing (once, a terminal tab) have none.
    public let grants: [String: String]

    public init(nonce: String, picker: String, grants: [String: String]) {
        (self.nonce, self.picker, self.grants) = (nonce, picker, grants)
    }

    public static func parse(_ challenge: String) -> ApprovalChallenge? {
        try? JSONDecoder().decode(ApprovalChallenge.self, from: Data(challenge.utf8))
    }

    /// As sent: the item's `challenge` string.
    public var encoded: String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! e.encode(self), as: UTF8.self)
    }
}

public enum DeviceKey {
    /// Lowercase hex of the first 16 bytes of SHA-256(raw 64-byte public key).
    public static func keyId(rawPublicKey: Data) -> String {
        hex(Data(SHA256.hash(data: rawPublicKey).prefix(16)))
    }

    /// The key ID's first 16 hex digits in groups of four, as both sides show it for comparing.
    public static func fingerprint(keyId: String) -> String {
        let digits = Array(keyId.prefix(16))
        return stride(from: 0, to: digits.count, by: 4).map { String(digits[$0..<min($0 + 4, digits.count)]) }
            .joined(separator: " ")
    }

    public static func verify(_ message: Data, signature: Data, rawPublicKey: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(rawRepresentation: rawPublicKey),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return key.isValidSignature(sig, for: message)
    }
}

public func sha256Hex(_ data: Data) -> String { hex(Data(SHA256.hash(data: data))) }

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

/// Whether a phone-approved entry stands: a currently paired phone signed an `approve` for
/// an option whose grant is exactly this entry. Editing the entry, moving it to another
/// session or command, or swapping in a longer option's expiry all change the payload hash.
public enum DeviceProofCheck {
    /// `device` returns the verified paired device with that key ID, if any.
    public static func verify(_ approval: Approval, device: (String) -> PairedDevice?) -> Bool {
        guard let proof = approval.deviceProof, let paired = device(proof.keyId),
              DeviceKey.verify(Data(proof.statement.utf8), signature: proof.signature, rawPublicKey: paired.publicKey),
              let statement = ApprovalStatement.parse(proof.statement),
              statement.keyId == proof.keyId, statement.action == "approve",
              let challenge = ApprovalChallenge.parse(statement.challenge),
              let pick = statement.picks[challenge.picker], let grant = challenge.grants[pick]
        else { return false }
        return grant == sha256Hex(approval.signedPayload)
    }
}
