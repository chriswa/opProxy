import CryptoKit
import FeedProtocol
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
