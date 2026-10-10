#if OPPROXY_TESTING
import CloudKit
import CryptoKit
import FeedProtocol
import Foundation

/// `opProxyRelay test-phone pair <qr-payload> | approve|deny [option] | share | reset`: plays
/// the iPhone app over CloudKit for Tests/cloud-e2e.sh, with a software key, its zone and its
/// pairing secret kept in OPPROXY_HOME. Its zone lives in this Mac's own private database, so
/// it exercises the same-Apple-ID path.
enum TestPhone {
    private static let container = CKContainer(identifier: CloudFeed.container)
    private static var db: CKDatabase { container.privateCloudDatabase }
    private static let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OPPROXY_HOME"] ?? NSTemporaryDirectory())

    private static func file(_ name: String) -> URL { home.appendingPathComponent("test-phone-" + name) }

    static func run(_ args: [String]) -> Never {
        let key = (try? Data(contentsOf: file("key"))).flatMap { try? P256.Signing.PrivateKey(rawRepresentation: $0) }
            ?? P256.Signing.PrivateKey()
        try? key.rawRepresentation.write(to: file("key"))
        let done = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task {
            do {
                switch args.first {
                case "pair" where args.count == 2: try await pair(args[1], key: key)
                case "approve", "deny": try await answer(args[0], pick: args.dropFirst().first, key: key)
                case "reset": try await reset()
                case "share":
                    let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: try zoneID())
                    print((try? await db.record(for: id)) == nil ? "no share" : "shared")
                default: throw Failure("usage: opProxyRelay test-phone pair <qr> | approve|deny [option] | share | reset")
                }
            } catch {
                print("FAILED: \(error)")
                code = 1
            }
            done.signal()
        }
        done.wait()
        exit(code)
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func zoneID() throws -> CKRecordZone.ID {
        guard let name = try? String(contentsOf: file("zone"), encoding: .utf8) else { throw Failure("not paired") }
        return CKRecordZone.ID(zoneName: name)
    }

    private static func pairing() throws -> PairingKey {
        guard let secret = try? Data(contentsOf: file("secret")) else { throw Failure("not paired") }
        return PairingKey(secret: secret)
    }

    private static func reset() async throws {
        if let zone = try? zoneID() { _ = try? await db.deleteRecordZone(withID: zone) }
        for name in ["zone", "secret"] { try? FileManager.default.removeItem(at: file(name)) }
        print("reset")
    }

    private static func pair(_ qr: String, key: P256.Signing.PrivateKey) async throws {
        guard let (code, macUser, macID, macAgreement) = CloudFeed.Rendezvous.parseSealed(qr: qr) else { throw Failure("bad QR payload") }
        // This stand-in phone shares the Mac's Apple ID, so there is nothing to share: the Mac
        // reads the zone from its own private database.
        guard macUser == (try await container.userRecordID().recordName) else { throw Failure("the QR code names another iCloud user") }
        let zone = CKRecordZone.ID(zoneName: CloudFeed.Rendezvous.zoneName(code: code))
        try zone.zoneName.write(to: file("zone"), atomically: true, encoding: .utf8)
        _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zone)], deleting: [])
        let rendezvous = CKRecord(recordType: CloudFeed.Rendezvous.type,
                                  recordID: CKRecord.ID(recordName: CloudFeed.Rendezvous.recordName(code: code)))
        rendezvous[CloudFeed.Rendezvous.sealed] = try CloudFeed.Rendezvous.seal(.ownZone(zone.zoneName), code: code)
        _ = try await container.publicCloudDatabase.save(rendezvous)
        defer { Task { _ = try? await container.publicCloudDatabase.deleteRecord(withID: rendezvous.recordID) } }
        print("rendezvous written")
        _ = try await waitFor(CKRecord.ID(recordName: CloudFeed.State.hello, zoneID: zone), seconds: 90)
        print("mac joined")
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        let statement = PairingHandshake.phoneStatement(phoneAgreementKey: agreement.publicKey.rawRepresentation,
                                                        macAgreementKey: macAgreement, macID: macID)
        var message = FeedReply.pair(publicKey: key.publicKey.rawRepresentation, name: "Cloud Test Phone")
        message[PairingHandshake.agreementKeyField] = agreement.publicKey.rawRepresentation.base64EncodedString()
        message[PairingHandshake.agreementSignatureField] = try key.signature(for: statement).derRepresentation.base64EncodedString()
        let response = try await send(message, zone: zone, key: nil)
        print("pair-result: \(response)")
        guard let json = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
              let sealed = (json[PairingHandshake.sealedSecretField] as? String).flatMap({ Data(base64Encoded: $0) }) else { return }
        let secret = try PairingHandshake.openSecret(sealed, phoneKey: agreement, macAgreementKey: macAgreement,
                                                     phoneDeviceKey: key.publicKey.rawRepresentation, macID: macID)
        try secret.write(to: file("secret"))
        print("pairing key received")
    }

    private static func answer(_ action: String, pick: String?, key: P256.Signing.PrivateKey) async throws {
        let zone = try zoneID(), pairing = try pairing()
        let deadline = Date() + 60
        while Date() < deadline {
            let changes = try await db.recordZoneChanges(inZoneWith: zone, since: nil)
            let pending = changes.modificationResultsByID.values.compactMap { try? $0.get().record }
                .filter { $0.recordType == CloudFeed.Item.type && $0.encryptedValues[CloudFeed.Item.note] == nil }
            if let record = pending.first, let value = record.encryptedValues[CloudFeed.Item.item] as? String {
                let json = try SealedField.open(value, with: pairing, recordType: CloudFeed.Item.type, field: CloudFeed.Item.item,
                                                recordName: record.recordID.recordName, from: .mac)
                guard let item = FeedItem.parse(json) else { throw Failure("the item didn't parse") }
                let message = try FeedReply.message(item: item, action: action, picks: pick.map { ["duration": $0] } ?? [:],
                                                    keyId: DeviceKey.keyId(rawPublicKey: key.publicKey.rawRepresentation)) {
                    try key.signature(for: $0).derRepresentation
                }
                print("reply-result: \(try await send(message, zone: zone, key: pairing))")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw Failure("no pending item appeared")
    }

    /// Writes an inbox message, sealed when there's a key, and waits for the Mac's response.
    private static func send(_ message: [String: Any], zone: CKRecordZone.ID, key: PairingKey?) async throws -> String {
        let id = CKRecord.ID(recordName: UUID().uuidString, zoneID: zone)
        let record = CKRecord(recordType: CloudFeed.Inbox.type, recordID: id)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]), as: UTF8.self)
        record.encryptedValues[CloudFeed.Inbox.message] = try key.map {
            try SealedField.seal(text, with: $0, recordType: CloudFeed.Inbox.type, field: CloudFeed.Inbox.message,
                                 recordName: id.recordName, from: .phone)
        } ?? text
        _ = try await db.save(record)
        let deadline = Date() + 60
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if let response = try await db.record(for: id).encryptedValues[CloudFeed.Inbox.response] as? String {
                guard let key else { return response }
                return try SealedField.open(response, with: key, recordType: CloudFeed.Inbox.type, field: CloudFeed.Inbox.response,
                                            recordName: id.recordName, from: .mac)
            }
        }
        throw Failure("the Mac never answered")
    }

    private static func waitFor(_ id: CKRecord.ID, seconds: Double) async throws -> CKRecord {
        let deadline = Date() + seconds
        while Date() < deadline {
            if let record = try? await db.record(for: id) { return record }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw Failure("timed out waiting for \(id.recordName)")
    }
}
#endif
