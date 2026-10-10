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
        XCTAssertNotEqual(pairing.commitment, PairingKey(secret: Data("other".utf8)).commitment)
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

    final class FakeOp {
        var calls: [[String]] = []
        var reply = ProxyResponse(exitCode: 0, stdout: Data(), stderr: Data())
        func run(_ argv: [String]) -> ProxyResponse {
            calls.append(argv)
            return reply
        }
    }

    static let generated = "Q7ux2Lk9fP3mZr8VbN4tWc6YhJ1sDa5Ge0KiXo2Rq9Tn3Mv7Lp4Bz8Hd6Fy1Cw5S"

    func item(title: String = "opProxy pairing key: iPhone · Studio", tags: [String] = ["opproxy-pairing"],
              category: String = "PASSWORD", password: String = generated) -> Data {
        let json: [String: Any] = [
            "id": "abc123", "title": title, "category": category, "tags": tags,
            "fields": [["id": "password", "type": "CONCEALED", "purpose": "PASSWORD", "label": "password", "value": password]],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testCreateLets1PasswordGenerateTheSecret() throws {
        let op = FakeOp()
        op.reply = ProxyResponse(exitCode: 0, stdout: item(), stderr: Data())
        let made = try PairingKeyVault(run: op.run).create(phoneName: "iPhone", macName: "Studio")
        XCTAssertEqual(made.itemId, "abc123")
        XCTAssertEqual(made.secret, Data(Self.generated.utf8))
        let argv = try XCTUnwrap(op.calls.first)
        XCTAssertEqual(argv.prefix(2), ["item", "create"])
        XCTAssertTrue(argv.contains("--generate-password=letters,digits,64"))
        XCTAssertTrue(argv.contains("opProxy pairing key: iPhone · Studio"))
        XCTAssertFalse(argv.contains { $0.contains(Self.generated) }, "the secret must never be on a command line")
    }

    func testLoadChecksTheItemIsAPairingKey() throws {
        let op = FakeOp()
        let vault = PairingKeyVault(run: op.run)
        op.reply = ProxyResponse(exitCode: 0, stdout: item(), stderr: Data())
        let key = try vault.load(itemId: "abc123", commitment: nil)
        XCTAssertEqual(key.id, PairingKey(secret: Data(Self.generated.utf8)).id)
        XCTAssertEqual(op.calls.last, ["item", "get", "abc123", "--format", "json", "--reveal"])

        for wrong in [item(title: "GitHub token"), item(tags: []), item(category: "LOGIN"), item(password: "short")] {
            op.reply = ProxyResponse(exitCode: 0, stdout: wrong, stderr: Data())
            XCTAssertThrowsError(try vault.load(itemId: "abc123", commitment: nil))
        }
    }

    func testLoadChecksTheCommitment() throws {
        let op = FakeOp()
        op.reply = ProxyResponse(exitCode: 0, stdout: item(), stderr: Data())
        let vault = PairingKeyVault(run: op.run)
        let right = PairingKey(secret: Data(Self.generated.utf8)).commitment
        XCTAssertNoThrow(try vault.load(itemId: "abc123", commitment: right))
        XCTAssertThrowsError(try vault.load(itemId: "abc123", commitment: PairingKey(secret: Data("x".utf8)).commitment))
    }

    func testLoadReportsOpsError() {
        let op = FakeOp()
        op.reply = ProxyResponse(exitCode: 1, stdout: Data(), stderr: Data("[ERROR] not signed in".utf8))
        XCTAssertThrowsError(try PairingKeyVault(run: op.run).load(itemId: "abc123", commitment: nil)) {
            XCTAssertEqual(($0 as? PairingKeyVault.Failure)?.description, "could not read the pairing key: [ERROR] not signed in")
        }
    }

    func testDeleteToleratesAnItemAlreadyGone() throws {
        let op = FakeOp()
        let vault = PairingKeyVault(run: op.run)
        try vault.delete(itemId: "abc123")
        XCTAssertEqual(op.calls.last, ["item", "delete", "abc123"])
        op.reply = ProxyResponse(exitCode: 1, stdout: Data(), stderr: Data(#"[ERROR] "abc123" isn't an item."#.utf8))
        XCTAssertNoThrow(try vault.delete(itemId: "abc123"))
        op.reply = ProxyResponse(exitCode: 1, stdout: Data(), stderr: Data("[ERROR] not signed in".utf8))
        XCTAssertThrowsError(try vault.delete(itemId: "abc123"))
    }

    func testPairingKeysAreRecognizedByTitle() {
        XCTAssertTrue(PairingKeyVault.isPairingKey(title: "opProxy pairing key: iPhone · Studio"))
        XCTAssertFalse(PairingKeyVault.isPairingKey(title: "GitHub token"))
    }
}
