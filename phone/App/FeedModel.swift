import CloudKit
import FeedProtocol
import Foundation
import SwiftUI
import UIKit

/// The phone's side of the approval feed. The phone owns a zone in its private database and
/// shares it with the Mac; the Mac writes requests and status into it, and the phone writes
/// replies into its inbox (CloudFeed in FeedProtocol).
@MainActor
final class FeedModel: ObservableObject {
    @Published private(set) var items: [FeedItem] = []
    @Published private(set) var status: FeedProviderStatus?
    /// The Mac's paired keys, from its `hello`; nil until the Mac has joined the zone. Kept
    /// on the phone too, so the app opens on the right screen before iCloud answers.
    @Published private(set) var pairedKeys: [String]? = UserDefaults.standard.stringArray(forKey: FeedModel.pairedKeysDefault) {
        didSet { UserDefaults.standard.set(pairedKeys, forKey: Self.pairedKeysDefault) }
    }
    /// Whether a fetch from iCloud has finished since the app last came to the foreground, so
    /// `paired` and `items` are more than a guess.
    @Published private(set) var loaded = false
    private static let pairedKeysDefault = "pairedKeys"
    @Published private(set) var lastError: String?

    /// A request the screen keeps showing while it acknowledges an answer, after it has left
    /// `items`.
    @Published private(set) var held: FeedItem?

    var paired: Bool { pairedKeys?.contains(PhoneKey.keyId) == true }
    /// The request on screen: the one being acknowledged, else the oldest pending.
    var current: FeedItem? { held ?? items.first }
    /// Pending requests behind the one on screen.
    var waiting: Int { items.filter { $0.id != current?.id }.count }

    /// Keeps `item` on screen until called again with nil, which lets it go with the
    /// queue's transition.
    func hold(_ item: FeedItem?) {
        if item == nil {
            withAnimation(.easeIn(duration: 0.35)) { held = nil }
        } else {
            held = item
        }
    }

    private let container = CKContainer(identifier: CloudFeed.container)
    private var db: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: CloudFeed.zoneName)
    private var token: CKServerChangeToken?
    private var ready = false
    private var subscribed = false
    private var refreshing = false
    private var poller: Task<Void, Never>?
    /// When the Mac last wrote its `hello`: it does so whenever it joins the zone.
    private var helloWrittenAt: Date?

    // MARK: Polling

    /// Polls every 2 seconds while the app is in the foreground: CloudKit only pushes new
    /// requests, not their removal or status changes. The model owns the loop, so nothing a
    /// view does can cancel a request in flight.
    func setActive(_ active: Bool) {
        guard active != (poller != nil) else { return }
        if active {
            poller = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        } else {
            poller?.cancel()
            poller = nil
            // What's on screen may be stale by the time the app is back: fetch before
            // claiming nothing is pending.
            update(\.loaded, false)
        }
    }

    /// Publishes only real changes, since each one redraws every view that watches the model.
    private func update<Value: Equatable>(_ path: ReferenceWritableKeyPath<FeedModel, Value>, _ value: Value) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

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
            update(\.lastError, nil)
        } catch let error as CKError where ready && error.code == .unknownItem {
            // No request has been written yet; try again later.
        } catch {
            report(error, in: "setUp")
        }
    }

    private static func subscription(_ zoneID: CKRecordZone.ID) -> CKSubscription {
        let subscription = CKQuerySubscription(recordType: CloudFeed.Item.type, predicate: NSPredicate(value: true),
                                               subscriptionID: "new-requests", options: [.firesOnRecordCreation])
        subscription.zoneID = zoneID
        let info = CKSubscription.NotificationInfo()
        info.title = "Secret Proxy"
        info.alertBody = "An agent is asking for a secret."
        info.soundName = "default"
        info.shouldSendMutableContent = true
        info.category = "request"
        subscription.notificationInfo = info
        return subscription
    }

    /// Shows a failure, unless it was only cancelled: a newer refresh is already on its way.
    private func report(_ error: Error, in step: String) {
        print("opProxy \(step): \(error)")
        if error is CancellationError || (error as? CKError)?.code == .operationCancelled { return }
        update(\.lastError, Self.describe(error))
    }

    /// What to tell someone about a CloudKit failure.
    private static func describe(_ error: Error) -> String {
        switch (error as? CKError)?.code {
        case .notAuthenticated: return "Sign in to iCloud in Settings to use Secret Proxy."
        case .networkUnavailable, .networkFailure: return "Offline. Requests will show up when you're back online."
        case .quotaExceeded: return "Your iCloud storage is full."
        default: return "iCloud: \(error.localizedDescription)"
        }
    }

    // MARK: Reading

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer {
            refreshing = false
            update(\.loaded, true)
        }
        await setUp()
        guard ready else { return }
        do {
            var more = true
            while more {
                let changes = try await db.recordZoneChanges(inZoneWith: zoneID, since: token)
                for case (_, .success(let change)) in changes.modificationResultsByID { apply(change.record) }
                for deletion in changes.deletions {
                    let id = deletion.recordID.recordName
                    update(\.items, items.filter { $0.id != id })
                }
                token = changes.changeToken
                more = changes.moreComing
            }
            update(\.lastError, nil)
        } catch let error as CKError where error.code == .changeTokenExpired {
            token = nil
        } catch {
            report(error, in: "refresh")
        }
    }

    private func apply(_ record: CKRecord) {
        switch record.recordType {
        case CloudFeed.Item.type:
            guard let json = record.encryptedValues[CloudFeed.Item.item] as? String, let item = FeedItem.parse(json) else { return }
            var pending = items.filter { $0.id != item.id }
            if record.encryptedValues[CloudFeed.Item.note] != nil {
                // Answered or timed out: its notification goes too.
                clearNotification(item.id)
            } else {
                pending.append(item)
                pending.sort { $0.createdAt < $1.createdAt }
            }
            update(\.items, pending)
        case CloudFeed.State.type:
            guard let json = record.encryptedValues[CloudFeed.State.message] as? String,
                  let message = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
            if record.recordID.recordName == CloudFeed.State.hello {
                helloWrittenAt = record.modificationDate
                update(\.pairedKeys, message["pairedKeys"] as? [String] ?? [])
            } else if let status = message["status"],
                      let data = try? JSONSerialization.data(withJSONObject: status) {
                update(\.status, try? JSONDecoder().decode(FeedProviderStatus.self, from: data))
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
            for _ in 0..<180 {
                try await Task.sleep(nanoseconds: 500_000_000)
                let current = try await db.record(for: record.recordID)
                guard let text = current.encryptedValues[CloudFeed.Inbox.response] as? String,
                      let response = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
                // The inbox record has served its purpose.
                _ = try? await db.deleteRecord(withID: record.recordID)
                await refresh()
                return response["ok"] as? Bool == true ? nil : (response["error"] as? String ?? "The Mac refused it.")
            }
            return "The Mac didn't answer. Is Secret Proxy running on it?"
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
        guard let (code, macUser) = CloudFeed.Rendezvous.parse(qr: qr) else {
            return "That isn't a Secret Proxy pairing code. If it came from an older Mac version, update it there."
        }
        await setUp()
        guard ready else { return lastError }
        let rendezvousID = CKRecord.ID(recordName: CloudFeed.Rendezvous.recordName(code: code))
        defer { Task { [db = container.publicCloudDatabase] in _ = try? await db.deleteRecord(withID: rendezvousID) } }
        do {
            progress("Inviting the Mac's iCloud account…")
            let inviting = Date()
            let invitation = try await invite(macUser)
            trace("invited in \(Self.seconds(since: inviting))")
            let started = Date()
            let rendezvous = CKRecord(recordType: CloudFeed.Rendezvous.type, recordID: rendezvousID)
            rendezvous[CloudFeed.Rendezvous.sealed] = try CloudFeed.Rendezvous.seal(invitation, code: code)
            _ = try await container.publicCloudDatabase.save(rendezvous)
            trace("wrote the rendezvous in \(Self.seconds(since: started))")

            // The Mac rewrites its `hello` once it has joined; an older one doesn't count.
            progress("Waiting for the Mac to join…")
            for _ in 0..<60 where !((helloWrittenAt ?? .distantPast) > started) {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                token = nil
                await refresh()
            }
            trace("hello written at \(helloWrittenAt.map { "\($0)" } ?? "never"); waited \(Self.seconds(since: started))")
            guard (helloWrittenAt ?? .distantPast) > started else { return "The Mac didn't join. Is its pairing window still open?" }
            // Sent even when already paired: the Mac answers at once, and its window closes.

            progress("Confirm on the Mac: check it shows the fingerprint below, then use Touch ID.")
            if let error = await send(FeedReply.pair(publicKey: PhoneKey.publicKey, name: UIDevice.current.name)) { return error }
            token = nil
            await refresh()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Lets the Mac's iCloud user, and only it, into this phone's zone. The share is never
    /// open to whoever holds its link: the Mac is invited by its user record, so the link
    /// works for no one else. Participants left from earlier pairings are removed.
    private func invite(_ macUser: String) async throws -> CloudFeed.Rendezvous.Invitation {
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        let existing = try? await db.record(for: id) as? CKShare
        trace("share: \(existing.map { Self.describe($0) } ?? "none"); Mac is \(macUser.prefix(10))")
        if macUser == (try await container.userRecordID().recordName) {
            // Same Apple ID: the Mac reads this zone directly, so a share would only be exposure.
            if existing != nil { _ = try await db.deleteRecord(withID: id) }
            return .ownZone(zoneID.zoneName)
        }
        let share = existing ?? CKShare(recordZoneID: zoneID)
        share.publicPermission = .none
        share[CKShare.SystemFieldKey.title] = "Secret Proxy requests"
        func isMac(_ participant: CKShare.Participant) -> Bool {
            participant.userIdentity.userRecordID?.recordName == macUser
        }
        for participant in share.participants where participant.role != .owner
            && !(isMac(participant) && participant.role == .privateUser) {
            share.removeParticipant(participant)
        }
        if !share.participants.contains(where: isMac) {
            let mac = try await container.shareParticipant(forUserRecordID: CKRecord.ID(recordName: macUser))
            mac.permission = .readWrite
            share.addParticipant(mac)
        }
        guard let saved = try await db.save(share) as? CKShare, let url = saved.url else { throw CKError(.internalError) }
        trace("saved share: \(Self.describe(saved))")
        return .share(url)
    }

    // MARK: Diagnostics

    /// Pairing steps with times, for the device console.
    private func trace(_ message: String) {
        print("opProxy pairing \(Date().formatted(date: .omitted, time: .standard)): \(message)")
    }

    private static func seconds(since start: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(start))
    }

    private static func describe(_ share: CKShare) -> String {
        "public \(share.publicPermission.rawValue), participants "
            + share.participants.map {
                "role \($0.role.rawValue) status \($0.acceptanceStatus.rawValue) user \($0.userIdentity.userRecordID?.recordName.prefix(10) ?? "?")"
            }.joined(separator: "; ")
    }
}
