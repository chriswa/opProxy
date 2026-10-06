import CryptoKit
import XCTest
@testable import OpProxyCore

final class DeviceProofTests: XCTestCase {
    var dir: URL!
    var devices: PairedDeviceStore!
    let phone = P256.Signing.PrivateKey()
    let key = ApprovalKey(audience: .session(agent: .claude, sessionId: "s"), argv: ["read", "op://a/b/c"], env: [:])
    let approvedAt = Date(timeIntervalSince1970: 1_000_000)
    var day: Date { ApprovalLifetime.day.expiry(from: approvedAt) }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("devices-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        devices = PairedDeviceStore(url: dir.appendingPathComponent("paired.json"), verify: ApprovalStoreTests.fakeVerify)
        try devices.pair(publicKey: phone.publicKey.rawRepresentation, name: "iPhone", sign: ApprovalStoreTests.fakeSign)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    var keyId: String { DeviceKey.keyId(rawPublicKey: phone.publicKey.rawRepresentation) }

    /// The challenge the feed would publish: grants for a day and forever from `approvedAt`,
    /// for this session and for all agents.
    var challenge: String {
        func grant(_ key: ApprovalKey, _ expires: Date) -> String {
            sha256Hex(Approval.payload(key: key, approvedAt: approvedAt, expiresAt: expires))
        }
        let all = key.reaching(.allAgents)
        return ApprovalChallenge(nonce: "n", picker: "duration", grants: [
            "1d": grant(key, day), "forever": grant(key, ApprovalStore.forever),
            "1d-all": grant(all, day), "forever-all": grant(all, ApprovalStore.forever),
        ]).encoded
    }

    func proof(pick: String = "1d", action: String = "approve", signer: P256.Signing.PrivateKey? = nil,
               edit: (String) -> String = { $0 }) throws -> DeviceProof {
        let statement = ApprovalStatement(id: "item", revision: 1, challenge: challenge, documentSha256: "d", action: action,
                                          picks: ["duration": pick], keyId: keyId, signedAt: 1)
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        let text = String(decoding: try e.encode(statement), as: UTF8.self)
        let signature = try (signer ?? phone).signature(for: Data(text.utf8)).derRepresentation
        return DeviceProof(keyId: keyId, statement: edit(text), signature: signature)
    }

    var url: URL { dir.appendingPathComponent("approvals.json") }

    func store() -> ApprovalStore {
        ApprovalStore(url: url, now: { self.approvedAt.addingTimeInterval(60) }, verify: { _, _ in false },
                      verifyDevice: { [devices] in DeviceProofCheck.verify($0, device: devices!.device(keyId:)) })
    }

    func approve(storing stored: ApprovalKey? = nil, expiresAt: Date? = nil, _ proof: DeviceProof) throws -> Bool {
        try store().approve(stored ?? key, sessionLabel: nil, itemLabel: nil, approvedAt: approvedAt, expiresAt: expiresAt ?? day,
                            proof: proof)
        return store().isApproved(key)
    }

    func testPhoneApprovalVerifies() throws {
        XCTAssertTrue(try approve(proof()))
        XCTAssertTrue(try approve(expiresAt: ApprovalStore.forever, proof(pick: "forever")))
        XCTAssertEqual(store().active.first?.deviceProof?.keyId, keyId)
    }

    func testTamperedStatementIsRejected() throws {
        XCTAssertFalse(try approve(proof(edit: { $0.replacingOccurrences(of: #""signedAt":1"#, with: #""signedAt":2"#) })))
    }

    func testOtherKeyIsRejected() throws {
        XCTAssertFalse(try approve(proof(signer: P256.Signing.PrivateKey())))
    }

    func testUnpairedPhoneIsRejected() throws {
        XCTAssertTrue(try approve(proof()))
        try devices.unpair { _ in true }
        XCTAssertFalse(store().isApproved(key), "unpairing ends the phone's lasting approvals")
    }

    func testDurationCantBeUpgraded() throws {
        XCTAssertFalse(try approve(proof(pick: "once")), "a 1-day entry backed by a statement that picked once")
        XCTAssertFalse(try approve(expiresAt: ApprovalStore.forever, proof(pick: "1d")), "picked 1 day, stored forever")
    }

    func testReachCantBeWidened() throws {
        let all = key.reaching(.allAgents)
        XCTAssertFalse(try approve(storing: all, proof(pick: "1d")), "picked this agent, stored for all agents")
        XCTAssertTrue(try approve(storing: all, proof(pick: "1d-all")))
        XCTAssertTrue(try approve(storing: all, expiresAt: ApprovalStore.forever, proof(pick: "forever-all")))
    }

    func testDenyGrantsNothing() throws {
        XCTAssertFalse(try approve(proof(action: "deny")))
    }

    func testEditedEntriesAreRejected() throws {
        XCTAssertTrue(try approve(proof()))
        func rewrite(_ edit: (inout [String: Any]) -> Void) throws {
            var entries = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
            edit(&entries[0])
            try JSONSerialization.data(withJSONObject: entries).write(to: url)
        }
        let original = try Data(contentsOf: url)
        try rewrite { $0["expiresAt"] = "2099-01-01T00:00:00Z" }
        XCTAssertFalse(store().isApproved(key), "extended expiry")
        try original.write(to: url)
        try rewrite { e in var k = e["key"] as! [String: Any]; k["audience"] = ["session": ["agent": "claude", "sessionId": "victim"]]; e["key"] = k }
        XCTAssertFalse(store().isApproved(key.reaching(.session(agent: .claude, sessionId: "victim"))), "moved to another session")
    }

    func testPairedDevicesMustBeSigned() throws {
        let file = dir.appendingPathComponent("paired.json")
        XCTAssertEqual(devices.devices.count, 1)
        let original = try Data(contentsOf: file)
        func rewrite(_ edit: (inout [String: Any]) -> Void) throws {
            try original.write(to: file)
            var entries = try JSONSerialization.jsonObject(with: original) as! [[String: Any]]
            edit(&entries[0])
            try JSONSerialization.data(withJSONObject: entries).write(to: file)
            Thread.sleep(forTimeInterval: 0.01)
        }
        let fresh = { PairedDeviceStore(url: file, verify: ApprovalStoreTests.fakeVerify) }
        try rewrite { $0["signature"] = nil }
        XCTAssertTrue(fresh().devices.isEmpty, "unsigned")
        try rewrite { $0["name"] = "Renamed" }
        XCTAssertTrue(fresh().devices.isEmpty, "edited after signing")
        let attacker = P256.Signing.PrivateKey().publicKey.rawRepresentation
        try rewrite { $0["publicKey"] = attacker.base64EncodedString() }
        XCTAssertTrue(fresh().devices.isEmpty, "key swapped under a signed entry")
        try rewrite {
            $0["publicKey"] = attacker.base64EncodedString()
            $0["keyId"] = DeviceKey.keyId(rawPublicKey: attacker)
        }
        XCTAssertTrue(fresh().devices.isEmpty, "key and key ID swapped")
        XCTAssertEqual(fresh().rejected.count, 1)
    }

    func testKeyIdAndFingerprint() {
        let id = DeviceKey.keyId(rawPublicKey: Data(0..<64))
        XCTAssertEqual(id, "fdeab9acf3710362bd2658cdc9a29e8f")
        XCTAssertEqual(DeviceKey.fingerprint(keyId: id), "fdea b9ac f371 0362")
    }
}
