#if OPPROXY_TESTING
import CloudKit
import CryptoKit
import Foundation
import OpProxyCore

/// `opProxy test-cloud-phone pair <qr-payload> | approve|deny [option]`: plays the iPhone app
/// over CloudKit for Tests/cloud-e2e.sh, with a software key kept in OPPROXY_HOME. Its zone
/// lives in this Mac's own private database, so it exercises the same-Apple-ID path.
enum CloudTestPhone {
    static let zoneID = CKRecordZone.ID(zoneName: "approvalFeedTest")
    private static let container = CKContainer(identifier: CloudFeed.container)
    private static var db: CKDatabase { container.privateCloudDatabase }

    static func run(_ args: [String], paths: Paths) -> Never {
        let keyFile = paths.stateDir.appendingPathComponent("test-phone-key")
        let key = (try? Data(contentsOf: keyFile)).flatMap { try? P256.Signing.PrivateKey(rawRepresentation: $0) }
            ?? P256.Signing.PrivateKey()
        try? key.rawRepresentation.write(to: keyFile)
        let done = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task {
            do {
                switch args.first {
                case "pair" where args.count == 2: try await pair(args[1], key: key)
                case "approve", "deny": try await answer(args[0], pick: args.dropFirst().first, key: key)
                case "reset": try await reset()
                case "share":
                    let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
                    print((try? await db.record(for: id)) == nil ? "no share" : "shared")
                default: throw Failure("usage: opProxy test-cloud-phone pair <qr> | approve|deny [option] | reset")
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

    private static func reset() async throws {
        _ = try? await db.deleteRecordZone(withID: zoneID)
        print("reset")
    }

    private static func pair(_ qr: String, key: P256.Signing.PrivateKey) async throws {
        guard let (code, macUser) = CloudFeed.Rendezvous.parse(qr: qr) else { throw Failure("bad QR payload") }
        // This stand-in phone shares the Mac's Apple ID, so there is nothing to share: the Mac
        // reads the zone from its own private database.
        guard macUser == (try await container.userRecordID().recordName) else { throw Failure("the QR code names another iCloud user") }
        _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        let rendezvous = CKRecord(recordType: CloudFeed.Rendezvous.type,
                                  recordID: CKRecord.ID(recordName: CloudFeed.Rendezvous.recordName(code: code)))
        rendezvous[CloudFeed.Rendezvous.sealed] = try CloudFeed.Rendezvous.seal(.ownZone(zoneID.zoneName), code: code)
        _ = try await container.publicCloudDatabase.save(rendezvous)
        defer { Task { _ = try? await container.publicCloudDatabase.deleteRecord(withID: rendezvous.recordID) } }
        print("rendezvous written")
        let hello = try await waitFor(CKRecord.ID(recordName: CloudFeed.State.hello, zoneID: zoneID), seconds: 90)
        print("mac joined: \(hello.encryptedValues[CloudFeed.State.message] as? String ?? "?")")
        let response = try await send(FeedReply.pair(publicKey: key.publicKey.rawRepresentation, name: "Cloud Test Phone"))
        print("pair-result: \(response)")
    }

    private static func answer(_ action: String, pick: String?, key: P256.Signing.PrivateKey) async throws {
        let deadline = Date() + 60
        while Date() < deadline {
            let changes = try await db.recordZoneChanges(inZoneWith: zoneID, since: nil)
            let pending = changes.modificationResultsByID.values.compactMap { try? $0.get().record }
                .filter { $0.recordType == CloudFeed.Item.type && $0.encryptedValues[CloudFeed.Item.note] == nil }
            if let record = pending.first, let json = record.encryptedValues[CloudFeed.Item.item] as? String,
               let item = FeedItem.parse(json) {
                let message = try FeedReply.message(item: item, action: action, picks: pick.map { ["duration": $0] } ?? [:],
                                                    keyId: DeviceKey.keyId(rawPublicKey: key.publicKey.rawRepresentation)) {
                    try key.signature(for: $0).derRepresentation
                }
                print("reply-result: \(try await send(message))")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw Failure("no pending item appeared")
    }

    private static func send(_ message: [String: Any]) async throws -> String {
        let record = CKRecord(recordType: CloudFeed.Inbox.type, recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
        let data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        record.encryptedValues[CloudFeed.Inbox.message] = String(decoding: data, as: UTF8.self)
        _ = try await db.save(record)
        let deadline = Date() + 60
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if let response = try await db.record(for: record.recordID).encryptedValues[CloudFeed.Inbox.response] as? String {
                return response
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
