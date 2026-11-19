import CryptoKit
import XCTest
@testable import OpProxyCore

final class PairingKeyTests: XCTestCase {
    let pairing = PairingKey(secret: Data(String(repeating: "a1", count: 32).utf8))
    let now = Date(timeIntervalSince1970: 1_000_000)

    func seal(_ body: String = "{}", name: String = "item-1", from sender: SealedRecord.Sender = .mac,
              at date: Date? = nil) throws -> Data {
        try SealedRecord.seal(Data(body.utf8), with: pairing, recordType: "FeedItem", recordName: name, from: sender,
                              at: date ?? now)
    }

    func open(_ sealed: Data, with key: PairingKey? = nil, type: String = "FeedItem", name: String = "item-1",
              from sender: SealedRecord.Sender = .mac, maxAge: TimeInterval? = 600) throws -> String {
        String(decoding: try SealedRecord.open(sealed, with: key ?? pairing, recordType: type, recordName: name, from: sender,
                                               maxAge: maxAge, now: now), as: UTF8.self)
    }

    func testSealedRecordRoundTrips() throws {
        XCTAssertEqual(try open(try seal(#"{"id":"item-1"}"#)), #"{"id":"item-1"}"#)
    }

    func testAnotherPairingCantOpenIt() throws {
        let other = PairingKey(secret: Data(String(repeating: "b2", count: 32).utf8))
        XCTAssertThrowsError(try open(try seal(), with: other)) { XCTAssertEqual($0 as? SealedRecord.Failure, .unreadable) }
    }

    func testCantMoveToAnotherRecordOrSender() throws {
        let sealed = try seal()
        XCTAssertThrowsError(try open(sealed, name: "item-2"))
        XCTAssertThrowsError(try open(sealed, type: "FeedState"))
        XCTAssertThrowsError(try open(sealed, from: .phone))
    }

    func testTamperingIsRefused() throws {
        var sealed = try seal()
        sealed[sealed.count / 2] ^= 1
        XCTAssertThrowsError(try open(sealed))
    }

    func testStaleCopiesAreRefused() throws {
        let old = try seal(at: now - 601)
        XCTAssertThrowsError(try open(old)) {
            XCTAssertEqual($0 as? SealedRecord.Failure, .stale(sealedAt: Date(timeIntervalSince1970: 1_000_000 - 601)))
        }
        XCTAssertNoThrow(try open(old, maxAge: nil))
        XCTAssertThrowsError(try open(try seal(at: now + SealedRecord.clockSkew + 1)))
        XCTAssertNoThrow(try open(try seal(at: now + 60)))
    }

    func testIdComesFromTheKeyAlone() {
        let again = PairingKey(secret: Data(String(repeating: "a1", count: 32).utf8))
        XCTAssertEqual(pairing.id, again.id)
        XCTAssertEqual(pairing.id.count, 32)
        XCTAssertNotEqual(pairing.id, PairingKey(secret: Data("other".utf8)).id)
    }

    // MARK: Handshake

    let device = P256.Signing.PrivateKey()
    let macKey = Curve25519.KeyAgreement.PrivateKey()
    let phoneKey = Curve25519.KeyAgreement.PrivateKey()

    func phoneSignature(macID: String = "mac-1", signer: P256.Signing.PrivateKey? = nil) throws -> Data {
        let statement = PairingHandshake.phoneStatement(phoneAgreementKey: phoneKey.publicKey.rawRepresentation,
                                                        macAgreementKey: macKey.publicKey.rawRepresentation, macID: macID)
        return try (signer ?? device).signature(for: statement).derRepresentation
    }

    func sealSecret(signature: Data, deviceKey: Data? = nil) throws -> Data {
        try PairingHandshake.sealSecret(Data("secret".utf8), macKey: macKey, phoneAgreementKey: phoneKey.publicKey.rawRepresentation,
                                        phoneSignature: signature, phoneDeviceKey: deviceKey ?? device.publicKey.rawRepresentation,
                                        macID: "mac-1")
    }

    func testHandshakeDeliversTheSecret() throws {
        let sealed = try sealSecret(signature: try phoneSignature())
        let secret = try PairingHandshake.openSecret(sealed, phoneKey: phoneKey, macAgreementKey: macKey.publicKey.rawRepresentation,
                                                     phoneDeviceKey: device.publicKey.rawRepresentation, macID: "mac-1")
        XCTAssertEqual(secret, Data("secret".utf8))
    }

    func testHandshakeNeedsThePairedDevicesSignatureForThisOffer() throws {
        XCTAssertThrowsError(try sealSecret(signature: try phoneSignature(signer: P256.Signing.PrivateKey())))
        XCTAssertThrowsError(try sealSecret(signature: try phoneSignature(macID: "mac-2")))
        let impostor = P256.Signing.PrivateKey()
        XCTAssertThrowsError(try sealSecret(signature: try phoneSignature(), deviceKey: impostor.publicKey.rawRepresentation))
    }

    func testOnlyThatPhoneCanOpenTheSecret() throws {
        let sealed = try sealSecret(signature: try phoneSignature())
        XCTAssertThrowsError(try PairingHandshake.openSecret(sealed, phoneKey: Curve25519.KeyAgreement.PrivateKey(),
                                                             macAgreementKey: macKey.publicKey.rawRepresentation,
                                                             phoneDeviceKey: device.publicKey.rawRepresentation, macID: "mac-1"))
    }

    // MARK: 1Password storage

    static let generated = "Q7ux2Lk9fP3mZr8VbN4tWc6YhJ1sDa5Ge0KiXo2Rq9Tn3Mv7Lp4Bz8Hd6Fy1Cw5S"
    static let vaults = [SDK.VaultOverview(id: "shared", title: "Engineering", vaultType: "userCreated"),
                         SDK.VaultOverview(id: "mine", title: "Employee", vaultType: "personal")]

    func item(title: String = "opProxy pairing key: iPhone · Studio", tags: [String] = ["opproxy-pairing"],
              category: String = "Password", password: String = generated) -> SDK.Item {
        SDK.Item(id: "abc123", title: title, category: category, vaultId: "mine",
                 fields: [SDK.Field(id: "password", title: "password", fieldType: "Concealed", value: password)], tags: tags)
    }

    func vault(_ op: FakeOnePassword) -> PairingKeyVault {
        PairingKeyVault { _ in .success(op) }
    }

    func testCreateLets1PasswordGenerateTheSecret() throws {
        let op = FakeOnePassword(vaults: Self.vaults)
        let made = try vault(op).create(phoneName: "iPhone", macName: "Studio")
        let item = try XCTUnwrap(op.stored.first)
        XCTAssertEqual(made.itemId, item.id)
        XCTAssertEqual(item.vaultId, "mine", "in the account's own vault")
        XCTAssertEqual(item.title, "opProxy pairing key: iPhone · Studio")
        XCTAssertEqual(item.tags, ["opproxy-pairing"])
        let secret = String(decoding: made.secret, as: UTF8.self)
        XCTAssertEqual(secret, item.fields.first?.value)
        XCTAssertEqual(secret.count, 64)
        XCTAssertTrue(secret.allSatisfy { $0.isLetter || $0.isNumber })
    }

    func testLoadChecksTheItemIsAPairingKey() throws {
        let op = FakeOnePassword(vaults: Self.vaults, items: [item()])
        let key = try vault(op).load(itemId: "abc123")
        XCTAssertEqual(key.id, PairingKey(secret: Data(Self.generated.utf8)).id)

        for wrong in [item(title: "GitHub token"), item(tags: []), item(category: "Login"), item(password: "short")] {
            op.stored = [wrong]
            XCTAssertThrowsError(try vault(op).load(itemId: "abc123"))
        }
    }

    func testLoadReports1PasswordsError() {
        let op = FakeOnePassword(vaults: Self.vaults, items: [item()])
        op.failure = SDK.Failure(.unauthorized, "invalid client id")
        XCTAssertThrowsError(try vault(op).load(itemId: "abc123")) {
            XCTAssertEqual(($0 as? PairingKeyVault.Failure)?.description, "could not read the pairing key: invalid client id")
        }
    }

    func testDeleteToleratesAnItemAlreadyGone() throws {
        let op = FakeOnePassword(vaults: Self.vaults, items: [item()])
        try vault(op).delete(itemId: "abc123")
        XCTAssertTrue(op.stored.isEmpty)
        XCTAssertNoThrow(try vault(op).delete(itemId: "abc123"))
        op.failure = SDK.Failure(.unauthorized, "invalid client id")
        XCTAssertThrowsError(try vault(op).delete(itemId: "abc123"))
    }

    func testPairingKeysAreRecognizedByTitle() {
        XCTAssertTrue(PairingKeyVault.isPairingKey(title: "opProxy pairing key: iPhone · Studio"))
        XCTAssertFalse(PairingKeyVault.isPairingKey(title: "GitHub token"))
    }
}
