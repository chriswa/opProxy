import CloudKit
import Foundation
import OpProxyCore
import Security

/// A paired iPhone's feed zone, which the Mac has joined (CloudFeed in FeedProtocol).
struct CloudLink: Codable, Equatable {
    let zoneName: String
    /// The zone owner's record name; `CKCurrentUserDefaultName` when the phone shares the Mac's Apple ID.
    let ownerName: String
    /// The zone is the phone's, on another Apple ID, so it lives in the Mac's shared database.
    let shared: Bool
    let linkedAt: Date

    var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName) }
}

/// Carries the approval feed through each linked phone's CloudKit zone. The feed's state is
/// mirrored as records, newest state winning, so a burst of changes to one item costs one
/// write; replies arrive as inbox records, polled quickly while anything is pending.
final class CloudTransport: FeedTransport {
    /// Whether this binary may use the container: CloudKit raises an exception rather than
    /// failing when it can't, and only a signed build with the provisioning profile can.
    static var available: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let ids = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
                as? [String]
        else { return false }
        return ids.contains(CloudFeed.container)
    }

    private let log: Log
    private let linksURL: URL
    private let container = CKContainer(identifier: CloudFeed.container)
    private weak var feed: ApprovalFeed?
    private let lock = NSLock()
    private var links: [CloudLink] = []
    private var mirror = Mirror()
    /// Per zone: records written since the zone last caught up, and its change token.
    private var dirty: [CKRecordZone.ID: Set<String>] = [:]
    private var tokens: [CKRecordZone.ID: CKServerChangeToken] = [:]
    /// Inbox records already handed to the feed, so a slow response isn't handled twice.
    private var handled: Set<CKRecord.ID> = []
    private var wake: CheckedContinuation<Void, Never>?
    /// A poke that came while the loop was busy: its next sleep returns at once.
    private var poked = false
    /// Pairing waits for a phone; poll the inbox quickly meanwhile.
    var pairingUntil = Date.distantPast

    /// What the zones should hold. Record name → JSON string; removed items keep their note
    /// for a while so a phone can say why one disappeared.
    private struct Mirror {
        var items: [String: (item: String, note: String?, removedAt: Date?)] = [:]
        var state: [String: String] = [:]
        var pending: Bool { items.values.contains { $0.note == nil } }
    }

    init(linksURL: URL, log: Log) {
        self.linksURL = linksURL
        self.log = log
        links = (try? JSONDecoder().decode([CloudLink].self, from: Data(contentsOf: linksURL))) ?? []
    }

    func attach(_ feed: ApprovalFeed) throws {
        self.feed = feed
        let state = feed.state()
        lock.withLock {
            mirror.state[CloudFeed.State.hello] = Self.string(FeedMessage.hello(pairedKeys: state.pairedKeys).json)
            if let status = state.status { mirror.state[CloudFeed.State.status] = Self.string(FeedMessage.status(status).json) }
            for (id, item) in state.items { mirror.items[id] = (Self.string(item), nil, nil) }
        }
        log.write("cloud feed: \(links.count) linked phone zone(s)")
        Task.detached { [self] in await run() }
    }

    func send(_ message: FeedMessage) {
        lock.withLock {
            switch message {
            case .hello: mirror.state[CloudFeed.State.hello] = Self.string(message.json)
            case .status: mirror.state[CloudFeed.State.status] = Self.string(message.json)
            case .upsert(let id, let item): mirror.items[id] = (Self.string(item), nil, nil)
            case .remove(let id, let note):
                guard let old = mirror.items[id] else { return }
                mirror.items[id] = (old.item, note, Date())
            }
            for link in links { dirty[link.zoneID, default: []].insert(Self.name(message)) }
        }
        poke()
    }

    /// Starts serving a phone's zone; the whole feed is written to it on the next pass.
    func link(_ link: CloudLink) {
        lock.withLock {
            links.removeAll { $0.zoneID == link.zoneID }
            links.append(link)
            dirty[link.zoneID] = nil
            tokens[link.zoneID] = nil
            saveLinks()
        }
        log.write("cloud feed: linked \(link.shared ? "shared" : "own") zone \(link.zoneName) of \(link.ownerName.prefix(10))")
        poke()
    }

    // MARK: The loop

    private func run() async {
        // First pass writes everything: records from a previous daemon are stale.
        var fresh = Set(lock.withLock { links.map(\.zoneID) })
        while true {
            for link in lock.withLock({ links }) {
                let full = fresh.remove(link.zoneID) != nil || lock.withLock { tokens[link.zoneID] == nil }
                do {
                    if full { lock.withLock { tokens[link.zoneID] = nil } }
                    let items = try await pull(link)
                    try await push(link, full: full, existing: items)
                } catch {
                    log.write("cloud feed: \(link.zoneName) of \(link.ownerName.prefix(10)): \(error)")
                    if (error as? CKError)?.code == .zoneNotFound || (error as? CKError)?.code == .userDeletedZone {
                        unlink(link)
                    } else {
                        lock.withLock { tokens[link.zoneID] = nil }
                    }
                }
            }
            prune()
            let quick = lock.withLock { mirror.pending } || pairingUntil > Date()
            await sleep(seconds: quick ? 2 : 30)
        }
    }

    /// Writes what changed (or everything) and deletes records the feed no longer has.
    /// `existing`: on a full pass, every item record in the zone.
    private func push(_ link: CloudLink, full: Bool, existing: [CKRecord.ID]) async throws {
        let db = database(link)
        let (mirror, names) = lock.withLock { () -> (Mirror, Set<String>) in
            defer { dirty[link.zoneID] = [] }
            return (self.mirror, dirty[link.zoneID] ?? [])
        }
        var save: [CKRecord] = []
        var delete: [CKRecord.ID] = []
        let wanted = full ? Set(mirror.items.keys).union(mirror.state.keys) : names
        for name in wanted {
            let id = CKRecord.ID(recordName: name, zoneID: link.zoneID)
            if let state = mirror.state[name] {
                let record = CKRecord(recordType: CloudFeed.State.type, recordID: id)
                record.encryptedValues[CloudFeed.State.message] = state
                save.append(record)
            } else if let item = mirror.items[name] {
                let record = CKRecord(recordType: CloudFeed.Item.type, recordID: id)
                record.encryptedValues[CloudFeed.Item.item] = item.item
                if let note = item.note { record.encryptedValues[CloudFeed.Item.note] = note }
                save.append(record)
            } else {
                delete.append(id)
            }
        }
        if full {
            // Items left over from before this daemon started (or that were pruned) go.
            delete += existing.filter { mirror.items[$0.recordName] == nil }
        }
        guard !save.isEmpty || !delete.isEmpty else { return }
        let (saved, deleted) = try await db.modifyRecords(saving: save, deleting: delete, savePolicy: .allKeys, atomically: false)
        for case (let id, .failure(let error)) in saved { throw Failure.record(id.recordName, error) }
        for case (let id, .failure(let error)) in deleted where (error as? CKError)?.code != .unknownItem {
            throw Failure.record(id.recordName, error)
        }
    }

    /// Reads new inbox records and hands each unanswered one to the feed. Returns the item
    /// records among the changes: all of them when the zone had no change token.
    private func pull(_ link: CloudLink) async throws -> [CKRecord.ID] {
        let db = database(link)
        var token = lock.withLock { tokens[link.zoneID] }
        var items: [CKRecord.ID] = []
        var more = true
        while more {
            let changes = try await db.recordZoneChanges(inZoneWith: link.zoneID, since: token)
            for case (let id, .success(let change)) in changes.modificationResultsByID {
                switch change.record.recordType {
                case CloudFeed.Inbox.type: handle(change.record, in: db)
                case CloudFeed.Item.type: items.append(id)
                default: break
                }
            }
            token = changes.changeToken
            more = changes.moreComing
        }
        lock.withLock { tokens[link.zoneID] = token }
        return items
    }

    private func handle(_ record: CKRecord, in db: CKDatabase) {
        guard record.encryptedValues[CloudFeed.Inbox.response] as? String == nil,
              let text = record.encryptedValues[CloudFeed.Inbox.message] as? String,
              let message = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              lock.withLock({ handled.insert(record.recordID).inserted }), let feed
        else { return }
        if message["type"] as? String == "pair" { pairingUntil = max(pairingUntil, Date() + 120) }
        feed.receive(message) { [self] response in
            record.encryptedValues[CloudFeed.Inbox.response] = Self.string(response)
            Task {
                do {
                    _ = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
                } catch {
                    log.write("cloud feed: couldn't answer \(record.recordID.recordName.prefix(8)): \(error)")
                }
                poke()
            }
        }
    }

    // MARK: Helpers

    private enum Failure: Error, CustomStringConvertible {
        case record(String, Error)
        var description: String {
            switch self { case .record(let name, let error): return "record \(name.prefix(12)): \(error)" }
        }
    }

    private func database(_ link: CloudLink) -> CKDatabase {
        link.shared ? container.sharedCloudDatabase : container.privateCloudDatabase
    }

    /// Removed items are forgotten after 10 minutes, and their records deleted.
    private func prune() {
        lock.withLock {
            let cutoff = Date() - 600
            for (id, item) in mirror.items where (item.removedAt ?? .distantFuture) < cutoff {
                mirror.items[id] = nil
                for link in links { dirty[link.zoneID, default: []].insert(id) }
            }
        }
    }

    private func unlink(_ link: CloudLink) {
        log.write("cloud feed: \(link.zoneName) of \(link.ownerName.prefix(10)) is gone; unlinking")
        lock.withLock {
            links.removeAll { $0.zoneID == link.zoneID }
            saveLinks()
        }
    }

    private func saveLinks() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(links).write(to: linksURL, options: .atomic)
    }

    private func poke() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { wake = nil }
            if wake == nil { poked = true }
            return wake
        }
        waiter?.resume()
    }

    private func sleep(seconds: Double) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if poked {
                    poked = false
                    return true
                }
                wake = continuation
                return false
            }
            if now { return continuation.resume() }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in self?.poke() }
        }
    }

    private static func name(_ message: FeedMessage) -> String {
        switch message {
        case .hello: return CloudFeed.State.hello
        case .status: return CloudFeed.State.status
        case .upsert(let id, _), .remove(let id, _): return id
        }
    }

    private static func string(_ json: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]),
               as: UTF8.self)
    }
}
