import CloudKit
import CryptoKit
import FeedProtocol
import Foundation
import SwiftUI
import UIKit

/// One Mac this phone is paired with (or pairing with): its zone and what it last wrote there.
struct MacFeed: Equatable {
    let zoneID: CKRecordZone.ID
    /// What the Mac calls itself.
    var name: String?
    /// The Mac's ID (`MacIdentity`), from its `hello`.
    var macID: String?
    /// What this phone calls it, if set here.
    var nickname: String?
    /// The opProxy version it runs, from its `hello`; nil from versions that didn't say.
    var version: String?
    /// The feed protocol it speaks, from its `hello`.
    var feedProtocol: Int?
    /// The Mac's paired keys, from its `hello`; nil until the Mac has joined the zone.
    var pairedKeys: [String]?
    var status: FeedProviderStatus?
    /// When the Mac last said it was awake; it does so while it has pending requests.
    var presenceAt: Date?
    var items: [FeedItem] = []
    /// When the Mac last wrote its `hello`: it does so whenever it joins the zone.
    var helloWrittenAt: Date?

    var paired: Bool { pairedKeys?.contains(PhoneKey.keyId) == true }
    var displayName: String { nickname ?? name ?? "Mac" }
    /// Whether it speaks a different feed protocol from this app. App versions may differ: a
    /// Mac can run its own build.
    var mismatched: Bool { feedProtocol.map { $0 != FeedProtocolVersion.current } ?? false }

    /// Whether the Mac has gone quiet with requests pending (asleep, or offline). A new
    /// request counts as hearing from it.
    func stuck(at now: Date) -> Bool {
        guard let newest = items.map(\.created).max() else { return false }
        return now.timeIntervalSince(max(presenceAt ?? .distantPast, newest)) > CloudFeed.State.presenceTimeout
    }
}

/// A request in the queue, with the Mac it came from.
struct QueuedRequest: Equatable, Identifiable {
    let mac: CKRecordZone.ID
    let macName: String
    let item: FeedItem
    /// From a Mac that has gone quiet: it can be dismissed, and never holds up the others.
    let stuck: Bool
    var id: String { mac.zoneName + "/" + item.id }
}

/// The phone's side of the approval feed. For each Mac it's paired with, the phone owns a zone
/// in its private database shared with that Mac alone; the Mac writes requests and status into
/// it, and the phone writes replies into its inbox (CloudFeed in FeedProtocol).
@MainActor
final class FeedModel: ObservableObject {
    /// By zone name.
    @Published private(set) var macs: [String: MacFeed] = [:]
    /// Whether a fetch from iCloud has finished since the app last came to the foreground, so
    /// `paired` and the queue are more than a guess.
    @Published private(set) var loaded = false
    @Published private(set) var lastError: String?
    /// A request the screen keeps showing while it acknowledges an answer, after it has left
    /// the queue.
    @Published private(set) var held: QueuedRequest?
    /// Stuck requests set aside on this phone.
    @Published private(set) var dismissed: Set<String> = []
    /// Moves on as time passes, so stuck Macs and expired requests are noticed without a
    /// change in iCloud.
    @Published private var now = Date()

    /// The Macs this phone was paired with when the app last ran, by zone name, so it opens on
    /// the right screen before iCloud answers.
    @Published private(set) var rememberedMacs: [String: String] = UserDefaults.standard.dictionary(forKey: FeedModel.macsDefault)
        as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(rememberedMacs, forKey: Self.macsDefault) }
    }
    private static let macsDefault = "pairedMacs"

    /// Names given to Macs on this phone, by zone name.
    @Published private(set) var nicknames: [String: String] = UserDefaults.standard.dictionary(forKey: FeedModel.nicknamesDefault)
        as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(nicknames, forKey: Self.nicknamesDefault) }
    }
    private static let nicknamesDefault = "macNicknames"

    /// Names a Mac on this phone; blank goes back to the Mac's own name.
    func setNickname(_ nickname: String, for mac: MacFeed) {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        nicknames[mac.zoneID.zoneName] = trimmed.isEmpty ? nil : String(trimmed.prefix(40))
        updateMac(mac.zoneID) { $0.nickname = nicknames[mac.zoneID.zoneName] }
        update(\.rememberedMacs, Dictionary(uniqueKeysWithValues: pairedMacs.map { ($0.zoneID.zoneName, $0.displayName) }))
    }

    // MARK: Demo

    /// Showing the pretend Mac in place of real ones.
    @Published private(set) var demo = false
    private var demoCount = 0

    func startDemo() {
        demo = true
        macs = [Demo.zone.zoneName: Demo.mac()]
        loaded = true
    }

    func addDemoRequest() {
        demoCount += 1
        updateMac(Demo.zone) { $0.items.append(Demo.request(number: demoCount)) }
    }

    #if DEBUG
    /// Screenshots: fixed sample state that never reaches iCloud.
    private var frozen = false

    func prepare(_ shot: Screenshot) {
        frozen = true
        loaded = true
        switch shot {
        case .pairing, .guide, .confirm:
            macs = [:]
        case .request, .allowed:
            var work = Demo.mac(name: "Work MacBook")
            work.items = [Demo.request(number: 1)]
            macs = [work.zoneID.zoneName: work]
        case .macs:
            let home = Demo.mac(zone: CKRecordZone.ID(zoneName: CloudFeed.zoneName(macID: "home")), name: "Home iMac")
            let work = Demo.mac(name: "Work MacBook")
            macs = [work.zoneID.zoneName: work, home.zoneID.zoneName: home]
        case .demo:
            startDemo()
        case .demoRequest:
            startDemo()
            addDemoRequest()
        }
    }
    #endif

    func exitDemo() {
        demo = false
        (macs, held, databaseToken, zoneTokens, subscribed) = ([:], nil, nil, [:], [])
        loaded = false
        Task { await refresh() }
    }

    /// This app's version, which every paired Mac's should match.
    nonisolated static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var pairedMacs: [MacFeed] { macs.values.filter(\.paired).sorted { $0.displayName < $1.displayName } }
    var paired: Bool { loaded ? !pairedMacs.isEmpty : !rememberedMacs.isEmpty }

    /// Every pending request: those from Macs that are answering first, oldest first, then
    /// those from Macs that have gone quiet.
    var queue: [QueuedRequest] {
        let all = macs.values.filter(\.paired).flatMap { mac in
            mac.items.map { QueuedRequest(mac: mac.zoneID, macName: mac.displayName, item: $0, stuck: mac.stuck(at: now)) }
        }
        // A request past its deadline has timed out on the Mac, or will when it wakes.
        return all.filter { !dismissed.contains($0.id) && ($0.item.expires.map { $0 > now } ?? true) }.sorted { a, b in
            a.stuck != b.stuck ? !a.stuck : a.item.createdAt < b.item.createdAt
        }
    }
    /// The request on screen: the one being acknowledged, else the first in the queue.
    var current: QueuedRequest? { held ?? queue.first }
    /// Pending requests behind the one on screen.
    var waiting: Int { queue.filter { $0.id != current?.id }.count }

    /// Keeps `request` on screen until called again with nil, which lets it go with the
    /// queue's transition.
    func hold(_ request: QueuedRequest?) {
        if request == nil {
            withAnimation(.easeIn(duration: 0.35)) { held = nil }
        } else {
            held = request
        }
    }

    /// Sets aside a stuck request on this phone. Its Mac still times it out when it wakes.
    func dismiss(_ request: QueuedRequest) {
        withAnimation(.easeIn(duration: 0.35)) { dismissed.insert(request.id) }
    }

    private let container = CKContainer(identifier: CloudFeed.container)
    private var db: CKDatabase { container.privateCloudDatabase }
    private var databaseToken: CKServerChangeToken?
    private var zoneTokens: [String: CKServerChangeToken] = [:]
    private var subscribed: Set<String> = []
    private var refreshing = false
    private var poller: Task<Void, Never>?
    /// Keeps `now` current to the second, so a request leaves as its countdown reaches 0:00.
    private var ticker: Task<Void, Never>?

    // MARK: Polling

    /// Polls every 2 seconds while the app is in the foreground: CloudKit doesn't push status
    /// changes, and iOS may hold back or drop its silent pushes for answered requests. The model owns the loop, so nothing a
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
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    self?.now = Date()
                }
            }
        } else {
            poller?.cancel()
            ticker?.cancel()
            (poller, ticker) = (nil, nil)
            // What's on screen may be stale by the time the app is back: fetch before
            // claiming nothing is pending.
            update(\.loaded, false)
        }
    }

    /// Publishes only real changes, since each one redraws every view that watches the model.
    private func update<Value: Equatable>(_ path: ReferenceWritableKeyPath<FeedModel, Value>, _ value: Value) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    private func updateMac(_ zone: CKRecordZone.ID, _ change: (inout MacFeed) -> Void) {
        var mac = macs[zone.zoneName] ?? MacFeed(zoneID: zone, nickname: nicknames[zone.zoneName])
        change(&mac)
        if macs[zone.zoneName] != mac { macs[zone.zoneName] = mac }
    }

    // MARK: Errors

    /// Shows a failure, unless it was only cancelled: a newer refresh is already on its way.
    private func report(_ error: Error, in step: String) {
        print("opProxy \(step): \(error)")
        if error is CancellationError || (error as? CKError)?.code == .operationCancelled { return }
        update(\.lastError, Self.describe(error))
    }

    /// What to tell someone about a CloudKit failure.
    static func describe(_ error: Error) -> String {
        switch (error as? CKError)?.code {
        case .notAuthenticated: return "Sign in to iCloud in Settings to use opProxy."
        case .networkUnavailable, .networkFailure: return "Offline. Requests will show up when you're back online."
        case .quotaExceeded: return "Your iCloud storage is full."
        default: return "iCloud: \(error.localizedDescription)"
        }
    }

    // MARK: Reading

    /// Fetches what changed: first which zones changed, across the database, then each of
    /// those zones' records.
    func refresh() async {
        // The demo's pretend Mac has nothing to fetch, and is always up to date.
        if demo { return update(\.loaded, true) }
        #if DEBUG
        if frozen { return }
        #endif
        guard !refreshing else { return }
        refreshing = true
        let started = Date()
        defer {
            refreshing = false
            update(\.now, Date())
        }
        do {
            var changed: [CKRecordZone.ID] = []
            var more = true
            while more {
                let changes = try await db.databaseChanges(since: databaseToken)
                changed += changes.modifications.map(\.zoneID)
                for deletion in changes.deletions {
                    macs[deletion.zoneID.zoneName] = nil
                    PairingSecrets.delete(zone: deletion.zoneID.zoneName)
                    zoneTokens[deletion.zoneID.zoneName] = nil
                    subscribed.remove(deletion.zoneID.zoneName)
                }
                databaseToken = changes.changeToken
                more = changes.moreComing
            }
            for zone in Set(changed) {
                if zone.zoneName == CloudFeed.legacyZoneName {
                    // From before a phone could serve several Macs: that Mac pairs again.
                    _ = try? await db.deleteRecordZone(withID: zone)
                } else if zone.zoneName.hasPrefix(CloudFeed.zonePrefix) || zone.zoneName.hasPrefix(CloudFeed.sealedZonePrefix) {
                    try await fetch(zone)
                }
            }
            for name in macs.keys where !subscribed.contains(name) { await subscribe(macs[name]!.zoneID) }
            update(\.lastError, nil)
            // Only a fetch that worked says which Macs there are.
            update(\.loaded, true)
            update(\.rememberedMacs, Dictionary(uniqueKeysWithValues: pairedMacs.map { ($0.zoneID.zoneName, $0.displayName) }))
            await clearNotifications(fetchedAt: started)
        } catch let error as CKError where error.code == .changeTokenExpired {
            (databaseToken, zoneTokens) = (nil, [:])
        } catch {
            report(error, in: "refresh")
        }
    }

    /// Fetches one zone's changes; from scratch, which also forgets a Mac with no `hello`.
    private func fetch(_ zone: CKRecordZone.ID, fromScratch: Bool = false) async throws {
        if fromScratch { zoneTokens[zone.zoneName] = nil }
        let full = zoneTokens[zone.zoneName] == nil
        var sawHello = false
        var more = true
        while more {
            let changes = try await db.recordZoneChanges(inZoneWith: zone, since: zoneTokens[zone.zoneName])
            for case (let id, .success(let change)) in changes.modificationResultsByID {
                sawHello = sawHello || id.recordName == CloudFeed.State.hello
                apply(change.record, zone: zone)
            }
            for deletion in changes.deletions {
                updateMac(zone) { mac in mac.items.removeAll { $0.id == deletion.recordID.recordName } }
            }
            zoneTokens[zone.zoneName] = changes.changeToken
            more = changes.moreComing
        }
        if full && !sawHello { updateMac(zone) { $0.pairedKeys = nil } }
    }

    private func apply(_ record: CKRecord, zone: CKRecordZone.ID) {
        switch record.recordType {
        case CloudFeed.Item.type:
            guard let json = PairingSecrets.macField(CloudFeed.Item.item, of: record), let item = FeedItem.parse(json) else { return }
            let answered = PairingSecrets.macField(CloudFeed.Item.note, of: record) != nil
            updateMac(zone) { mac in
                mac.items.removeAll { $0.id == item.id }
                if !answered {
                    mac.items.append(item)
                    mac.items.sort { $0.createdAt < $1.createdAt }
                }
            }
        case CloudFeed.State.type:
            // A sealed zone's Mac writes an empty `hello` until it has handed over the pairing
            // key: that it wrote one at all says it joined.
            if record.recordID.recordName == CloudFeed.State.hello {
                updateMac(zone) { $0.helloWrittenAt = record.modificationDate }
            }
            guard let json = PairingSecrets.macField(CloudFeed.State.message, of: record),
                  let message = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
            updateMac(zone) { mac in
                switch record.recordID.recordName {
                case CloudFeed.State.hello:
                    mac.pairedKeys = message["pairedKeys"] as? [String] ?? []
                    mac.name = (message["mac"] as? [String: Any])?["name"] as? String
                    mac.macID = (message["mac"] as? [String: Any])?["id"] as? String
                    mac.version = (message["mac"] as? [String: Any])?["version"] as? String
                    mac.feedProtocol = message["protocol"] as? Int
                case CloudFeed.State.presence:
                    mac.presenceAt = (message["aliveAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                case CloudFeed.State.status:
                    if let status = message["status"], let data = try? JSONSerialization.data(withJSONObject: status) {
                        mac.status = try? JSONDecoder().decode(FeedProviderStatus.self, from: data)
                    }
                default:
                    break
                }
            }
        default:
            break
        }
    }

    /// Takes down the notifications of requests that aren't in the queue: answered, timed out,
    /// dismissed, or from a Mac no longer paired. Only after a fetch that worked, so the queue
    /// is complete. A notification delivered just before the fetch began may be for a request
    /// the fetch didn't see yet; the next fetch decides about it.
    private func clearNotifications(fetchedAt: Date) async {
        // In the background nothing keeps `now` current, and the queue leaves out expired requests.
        update(\.now, Date())
        let pending = Set(queue.map(\.id))
        await RequestNotifications.remove { record, note in
            note.date < fetchedAt - 10 && !pending.contains(record.zoneID.zoneName + "/" + record.recordName)
        }
    }

    /// The zone's subscriptions: a push for each request the Mac writes, which the
    /// notification extension fills in, and a silent one when the Mac answers or deletes a
    /// request, which wakes the app to take down its notification.
    private func subscribe(_ zone: CKRecordZone.ID) async {
        let created = CKQuerySubscription(recordType: CloudFeed.Item.type, predicate: NSPredicate(value: true),
                                          subscriptionID: "new-requests-\(zone.zoneName)", options: [.firesOnRecordCreation])
        created.zoneID = zone
        let info = CKSubscription.NotificationInfo()
        info.title = "opProxy"
        info.alertBody = "An agent is asking for a secret."
        info.soundName = "default"
        info.shouldSendMutableContent = true
        info.category = "request"
        created.notificationInfo = info
        let changed = CKQuerySubscription(recordType: CloudFeed.Item.type, predicate: NSPredicate(value: true),
                                          subscriptionID: "changed-requests-\(zone.zoneName)",
                                          options: [.firesOnRecordUpdate, .firesOnRecordDeletion])
        changed.zoneID = zone
        let silent = CKSubscription.NotificationInfo()
        silent.shouldSendContentAvailable = true
        changed.notificationInfo = silent
        do {
            _ = try await db.modifySubscriptions(saving: [created, changed], deleting: [])
            subscribed.insert(zone.zoneName)
        } catch {
            report(error, in: "subscribe")
        }
    }

    // MARK: Writing

    /// How long to wait for a Mac to accept an answer before saying it isn't answering.
    nonisolated private static let answerTimeout: TimeInterval = 15

    /// Writes `message` to the zone's inbox and waits for the Mac's answer: nil if it was
    /// accepted and `accepted` finds nothing wrong with it, else why not. In a sealed zone both
    /// are sealed once there's a pairing key; until then (the `pair` message) neither is.
    func send(_ message: [String: Any], to zone: CKRecordZone.ID, timeout: TimeInterval = FeedModel.answerTimeout,
              accepted: ([String: Any]) -> String? = { _ in nil }) async -> String? {
        do {
            let record = CKRecord(recordType: CloudFeed.Inbox.type,
                                  recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zone))
            let data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])
            let key = PairingSecrets.key(zone: zone.zoneName)
            let text = String(decoding: data, as: UTF8.self)
            record.encryptedValues[CloudFeed.Inbox.message] = try key.map {
                try SealedField.seal(text, with: $0, recordType: CloudFeed.Inbox.type, field: CloudFeed.Inbox.message,
                                     recordName: record.recordID.recordName, from: .phone)
            } ?? text
            _ = try await db.save(record)
            let deadline = Date() + timeout
            while Date() < deadline {
                try await Task.sleep(nanoseconds: 500_000_000)
                let current = try await db.record(for: record.recordID)
                guard let text = key == nil ? current.encryptedValues[CloudFeed.Inbox.response] as? String
                        : PairingSecrets.macField(CloudFeed.Inbox.response, of: current),
                      let response = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
                // The inbox record has served its purpose.
                _ = try? await db.deleteRecord(withID: record.recordID)
                let error = response["ok"] as? Bool == true ? accepted(response)
                    : (response["error"] as? String ?? "The Mac refused it.")
                await refresh()
                return error
            }
            // Left unanswered, the Mac refuses it as too old if it wakes later.
            _ = try? await db.deleteRecord(withID: record.recordID)
            return "The Mac isn't answering. It may be asleep or offline."
        } catch {
            return Self.describe(error)
        }
    }

    func answer(_ request: QueuedRequest, action: String, picks: [String: String]) async -> String? {
        if demo {
            // The pretend Mac takes a moment, as a real one would.
            try? await Task.sleep(nanoseconds: 900_000_000)
            updateMac(request.mac) { mac in mac.items.removeAll { $0.id == request.item.id } }
            return nil
        }
        do {
            let message = try FeedReply.message(item: request.item, action: action, picks: picks, keyId: PhoneKey.keyId,
                                                sign: PhoneKey.sign)
            return await send(message, to: request.mac)
        } catch {
            return "Couldn't sign the reply: \(error.localizedDescription)"
        }
    }

    // MARK: Pairing

    /// Forgets a Mac: deletes its zone, which ends that Mac's access (it drops the link when
    /// it next looks). Other Macs are untouched.
    func unpair(_ mac: MacFeed) async -> String? {
        if demo {
            exitDemo()
            return nil
        }
        do {
            _ = try await db.deleteRecordZone(withID: mac.zoneID)
        } catch let error as CKError where error.code == .zoneNotFound {
            // Already gone.
        } catch {
            return Self.describe(error)
        }
        macs[mac.zoneID.zoneName] = nil
        zoneTokens[mac.zoneID.zoneName] = nil
        subscribed.remove(mac.zoneID.zoneName)
        update(\.rememberedMacs, rememberedMacs.filter { $0.key != mac.zoneID.zoneName })
        nicknames[mac.zoneID.zoneName] = nil
        PairingSecrets.delete(zone: mac.zoneID.zoneName)
        return nil
    }

    /// Makes a zone for the Mac whose QR code was scanned and shares it with that Mac, waits
    /// for it to join, then asks it to trust this phone's key. A version 4 code's zone is new
    /// and sealed: the Mac's answer brings the pairing key, and once it has, the Mac's earlier
    /// pairings with this phone are deleted. Returns nil once paired, else why not.
    func pair(qr: String, progress: @escaping (String) -> Void) async -> String? {
        let code: Data, macUser: String, macID: String, zone: CKRecordZone.ID
        /// Version 4: this attempt's agreement key, and the Mac's.
        let handshake: (phoneKey: Curve25519.KeyAgreement.PrivateKey, macKey: Data)?
        if let offer = CloudFeed.Rendezvous.parseSealed(qr: qr) {
            (code, macUser, macID) = (offer.code, offer.macUser, offer.macID)
            zone = CKRecordZone.ID(zoneName: CloudFeed.Rendezvous.zoneName(code: offer.code))
            handshake = (Curve25519.KeyAgreement.PrivateKey(), offer.agreementKey)
        } else if let offer = CloudFeed.Rendezvous.parse(qr: qr) {
            (code, macUser, macID) = offer
            zone = CKRecordZone.ID(zoneName: CloudFeed.zoneName(macID: macID))
            handshake = nil
        } else {
            return "That isn't an opProxy pairing code. If it came from an older Mac version, update it there."
        }
        let error = await pair(zone: zone, code: code, macUser: macUser, macID: macID, handshake: handshake, progress: progress)
        if error == nil {
            for old in macs.values where old.zoneID != zone
                && (old.macID == macID || old.zoneID.zoneName == CloudFeed.zoneName(macID: macID)) {
                _ = await unpair(old)
            }
        } else if handshake != nil {
            // A sealed zone is this attempt's alone; one that didn't pair is no use to anyone.
            _ = try? await db.deleteRecordZone(withID: zone)
            PairingSecrets.delete(zone: zone.zoneName)
        }
        return error
    }

    private func pair(zone: CKRecordZone.ID, code: Data, macUser: String, macID: String,
                      handshake: (phoneKey: Curve25519.KeyAgreement.PrivateKey, macKey: Data)?,
                      progress: @escaping (String) -> Void) async -> String? {
        let rendezvousID = CKRecord.ID(recordName: CloudFeed.Rendezvous.recordName(code: code))
        defer { Task { [db = container.publicCloudDatabase] in _ = try? await db.deleteRecord(withID: rendezvousID) } }
        do {
            progress("Inviting the Mac's iCloud account…")
            _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zone)], deleting: [])
            await subscribe(zone)
            let invitation = try await invite(macUser, to: zone)
            let started = Date()
            let rendezvous = CKRecord(recordType: CloudFeed.Rendezvous.type, recordID: rendezvousID)
            rendezvous[CloudFeed.Rendezvous.sealed] = try CloudFeed.Rendezvous.seal(invitation, code: code)
            _ = try await container.publicCloudDatabase.save(rendezvous)

            // The Mac rewrites its `hello` once it has joined; an older one doesn't count.
            progress("Waiting for the Mac to join…")
            func joined() -> Bool { (macs[zone.zoneName]?.helloWrittenAt ?? .distantPast) > started }
            for _ in 0..<60 where !joined() {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                try await fetch(zone, fromScratch: true)
            }
            guard joined() else { return "The Mac didn't join. Is its pairing window still open?" }

            // Sent even when already paired: the Mac answers at once, and its window closes.
            progress("Confirm on the Mac: check it shows the fingerprint below, then use Touch ID.")
            var message = FeedReply.pair(publicKey: PhoneKey.publicKey, name: UIDevice.current.name)
            if let handshake {
                let mine = handshake.phoneKey.publicKey.rawRepresentation
                let statement = PairingHandshake.phoneStatement(phoneAgreementKey: mine, macAgreementKey: handshake.macKey, macID: macID)
                message[PairingHandshake.agreementKeyField] = mine.base64EncodedString()
                message[PairingHandshake.agreementSignatureField] = try PhoneKey.sign(statement).base64EncodedString()
            }
            if let error = await send(message, to: zone, timeout: 120, accepted: { response in
                guard let handshake else { return nil }
                guard let sealed = (response[PairingHandshake.sealedSecretField] as? String).flatMap({ Data(base64Encoded: $0) })
                else { return "The Mac paired without sending a pairing key. Update opProxy on the Mac, then pair again." }
                guard let secret = try? PairingHandshake.openSecret(sealed, phoneKey: handshake.phoneKey,
                                                                    macAgreementKey: handshake.macKey,
                                                                    phoneDeviceKey: PhoneKey.publicKey, macID: macID)
                else { return "The pairing key from the Mac didn't open. Pair again." }
                return PairingSecrets.save(secret, zone: zone.zoneName) ? nil : "Couldn't keep the pairing key in this phone's keychain."
            }) { return error }
            try await fetch(zone, fromScratch: true)
            await refresh()
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    /// Lets the Mac's iCloud user, and only it, into the zone. The share is never open to
    /// whoever holds its link: the Mac is invited by its user record, so the link works for no
    /// one else. Participants left from earlier pairings are removed.
    private func invite(_ macUser: String, to zone: CKRecordZone.ID) async throws -> CloudFeed.Rendezvous.Invitation {
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone)
        let existing = try? await db.record(for: id) as? CKShare
        if macUser == (try await container.userRecordID().recordName) {
            // Same Apple ID: the Mac reads this zone directly, so a share would only be exposure.
            if existing != nil { _ = try await db.deleteRecord(withID: id) }
            return .ownZone(zone.zoneName)
        }
        let share = existing ?? CKShare(recordZoneID: zone)
        share.publicPermission = .none
        share[CKShare.SystemFieldKey.title] = "opProxy requests"
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
        return .share(url)
    }
}
