import CloudKit
import FeedProtocol
import Foundation
import UIKit

/// The phone's side of the approval feed. The phone owns a zone in its private database and
/// shares it with the Mac; the Mac writes requests and status into it, and the phone writes
/// replies into its inbox (CloudFeed in FeedProtocol).
@MainActor
final class FeedModel: ObservableObject {
    struct Removed: Equatable {
        let item: FeedItem
        let note: String
    }

    @Published private(set) var items: [FeedItem] = []
    @Published private(set) var removed: [String: Removed] = [:]
    @Published private(set) var status: FeedProviderStatus?
    /// The Mac's paired keys, from its `hello`; nil until the Mac has joined the zone.
    @Published private(set) var pairedKeys: [String]?
    @Published private(set) var lastError: String?
    /// A request to open, from a tapped notification.
    @Published var focus: String?

    var paired: Bool { pairedKeys?.contains(PhoneKey.keyId) == true }

    private let container = CKContainer(identifier: CloudFeed.container)
    private var db: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: CloudFeed.zoneName)
    private var token: CKServerChangeToken?
    private var ready = false
    private var subscribed = false
    private var refreshing = false

    // MARK: Setup

    /// Makes the zone, then the new-request subscription. The subscription needs the
    /// request record type to exist, which in development it only does once the Mac has
    /// written a request, so it's retried on every refresh until it saves.
    func setUp() async {
        do {
            if !ready {
                _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
                ready = true
            }
            if !subscribed {
                _ = try await db.modifySubscriptions(saving: [Self.subscription(zoneID)], deleting: [])
                subscribed = true
            }
            lastError = nil
        } catch let error as CKError where ready && error.code == .unknownItem {
            // No request has been written yet; try again later.
        } catch {
            lastError = "Couldn't reach iCloud: \(error.localizedDescription)"
        }
    }

    private static func subscription(_ zoneID: CKRecordZone.ID) -> CKSubscription {
        let subscription = CKQuerySubscription(recordType: CloudFeed.Item.type, predicate: NSPredicate(value: true),
                                               subscriptionID: "new-requests", options: [.firesOnRecordCreation])
        subscription.zoneID = zoneID
        let info = CKSubscription.NotificationInfo()
        info.title = "opProxy"
        info.alertBody = "An agent is asking for a 1Password secret."
        info.soundName = "default"
        info.shouldSendMutableContent = true
        info.category = "request"
        subscription.notificationInfo = info
        return subscription
    }

    // MARK: Reading

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await setUp()
        guard ready else { return }
        do {
            var more = true
            while more {
                let changes = try await db.recordZoneChanges(inZoneWith: zoneID, since: token)
                for case (_, .success(let change)) in changes.modificationResultsByID { apply(change.record) }
                for deletion in changes.deletions {
                    items.removeAll { $0.id == deletion.recordID.recordName }
                    removed[deletion.recordID.recordName] = nil
                }
                token = changes.changeToken
                more = changes.moreComing
            }
            lastError = nil
        } catch let error as CKError where error.code == .changeTokenExpired {
            token = nil
        } catch {
            lastError = "Couldn't refresh: \(error.localizedDescription)"
        }
    }

    private func apply(_ record: CKRecord) {
        switch record.recordType {
        case CloudFeed.Item.type:
            guard let json = record.encryptedValues[CloudFeed.Item.item] as? String, let item = FeedItem.parse(json) else { return }
            items.removeAll { $0.id == item.id }
            if let note = record.encryptedValues[CloudFeed.Item.note] as? String {
                removed[item.id] = Removed(item: item, note: note)
                clearNotification(item.id)
            } else {
                items.append(item)
                items.sort { $0.createdAt < $1.createdAt }
            }
        case CloudFeed.State.type:
            guard let json = record.encryptedValues[CloudFeed.State.message] as? String,
                  let message = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
            if record.recordID.recordName == CloudFeed.State.hello {
                pairedKeys = message["pairedKeys"] as? [String] ?? []
            } else if let status = message["status"],
                      let data = try? JSONSerialization.data(withJSONObject: status) {
                self.status = try? JSONDecoder().decode(FeedProviderStatus.self, from: data)
            }
        default:
            break
        }
    }

    private func clearNotification(_ id: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notes in
            let ids = notes.filter { $0.request.content.userInfo["itemId"] as? String == id }.map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    // MARK: Writing

    /// Writes `message` to the inbox and waits for the Mac's answer: nil if it was accepted,
    /// else why not.
    func send(_ message: [String: Any]) async -> String? {
        do {
            let record = CKRecord(recordType: CloudFeed.Inbox.type,
                                  recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
            let data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])
            record.encryptedValues[CloudFeed.Inbox.message] = String(decoding: data, as: UTF8.self)
            _ = try await db.save(record)
            for _ in 0..<90 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let current = try await db.record(for: record.recordID)
                guard let text = current.encryptedValues[CloudFeed.Inbox.response] as? String,
                      let response = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
                // The inbox record has served its purpose.
                _ = try? await db.deleteRecord(withID: record.recordID)
                await refresh()
                return response["ok"] as? Bool == true ? nil : (response["error"] as? String ?? "The Mac refused it.")
            }
            return "The Mac didn't answer. Is opProxy running on it?"
        } catch {
            return error.localizedDescription
        }
    }

    func answer(_ item: FeedItem, action: String, picks: [String: String]) async -> String? {
        do {
            let message = try FeedReply.message(item: item, action: action, picks: picks, keyId: PhoneKey.keyId,
                                                sign: PhoneKey.sign)
            return await send(message)
        } catch {
            return "Couldn't sign the reply: \(error.localizedDescription)"
        }
    }

    // MARK: Pairing

    /// Shares the zone with the Mac whose QR code was scanned, waits for it to join, then asks
    /// it to trust this phone's key. Returns nil once paired, else why not.
    func pair(qr: String, progress: @escaping (String) -> Void) async -> String? {
        guard let code = CloudFeed.Rendezvous.code(fromQR: qr) else { return "That isn't an opProxy pairing code." }
        await setUp()
        guard ready else { return lastError }
        let rendezvousID = CKRecord.ID(recordName: CloudFeed.Rendezvous.recordName(code: code))
        defer { Task { [db = container.publicCloudDatabase] in _ = try? await db.deleteRecord(withID: rendezvousID) } }
        do {
            progress("Sharing this phone's request list with the Mac…")
            let url = try await shareURL()
            let rendezvous = CKRecord(recordType: CloudFeed.Rendezvous.type, recordID: rendezvousID)
            rendezvous[CloudFeed.Rendezvous.sealed] = try CloudFeed.Rendezvous.seal(url, code: code)
            _ = try await container.publicCloudDatabase.save(rendezvous)

            progress("Waiting for the Mac to join…")
            let before = pairedKeys
            pairedKeys = nil
            for _ in 0..<60 where pairedKeys == nil {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                token = nil
                await refresh()
            }
            guard pairedKeys != nil else {
                pairedKeys = before
                return "The Mac didn't join. Is its pairing window still open?"
            }
            if paired { return nil }

            progress("Confirm on the Mac: check it shows \(PhoneKey.fingerprint), then use Touch ID.")
            if let error = await send(FeedReply.pair(publicKey: PhoneKey.publicKey, name: UIDevice.current.name)) { return error }
            token = nil
            await refresh()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The zone's share: anyone with its URL can join, and only the Mac ever gets it.
    private func shareURL() async throws -> URL {
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        if let existing = try? await db.record(for: id) as? CKShare, let url = existing.url { return url }
        let share = CKShare(recordZoneID: zoneID)
        share.publicPermission = .readWrite
        share[CKShare.SystemFieldKey.title] = "opProxy approvals"
        guard let saved = try await db.save(share) as? CKShare, let url = saved.url else {
            throw CKError(.internalError)
        }
        return url
    }
}
