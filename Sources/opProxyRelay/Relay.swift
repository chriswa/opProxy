import CloudKit
import FeedProtocol
import Foundation

/// Keeps each linked phone zone's records matching what the daemon put there, newest state
/// winning, so a burst of changes to one record costs one write; reports unanswered inbox
/// records, polled quickly while the daemon says something's pending. Every field value is
/// opaque here: the daemon seals them, and the phone opens them.
final class Relay {
    private struct Link: Equatable {
        let zoneID: CKRecordZone.ID
        let shared: Bool
    }

    private struct Record: Equatable {
        let type: String
        let fields: [String: String]
    }

    private let emit: (RelayEvent) -> Void
    private let container = CKContainer(identifier: CloudFeed.container)
    private let lock = NSLock()
    private var links: [String: Link] = [:]
    /// Zone → record name → what it should hold.
    private var records: [String: [String: Record]] = [:]
    /// Per zone: records changed since the zone last caught up, and its change token.
    private var dirty: [String: Set<String>] = [:]
    private var tokens: [String: CKServerChangeToken] = [:]
    /// Zones to write in full on their next pass.
    private var fresh: Set<String> = []
    /// Inbox records already reported, so a slow answer isn't asked for twice.
    private var reported: [String: Set<String>] = [:]
    private var quick = false
    private var rendezvous: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    /// A poke that came while the loop was busy: its next sleep returns at once.
    private var poked = false

    init(emit: @escaping (RelayEvent) -> Void) {
        self.emit = emit
    }

    func start() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        emit(.ready(version: version, protocolVersion: RelayProtocol.version))
        Task.detached { [self] in await run() }
    }

    func handle(_ command: RelayCommand) {
        switch command {
        case .link(let zone, let owner, let shared):
            lock.withLock {
                // An empty owner is this Mac's own iCloud user (the phone shares its Apple ID).
                links[zone] = Link(zoneID: CKRecordZone.ID(zoneName: zone, ownerName: owner.isEmpty ? CKCurrentUserDefaultName : owner),
                                   shared: shared)
                fresh.insert(zone)
                tokens[zone] = nil
                // The daemon links again once it can open what it's sent, so report everything anew.
                reported[zone] = nil
            }
        case .unlink(let zone):
            lock.withLock {
                links[zone] = nil
                records[zone] = nil
                dirty[zone] = nil
                tokens[zone] = nil
            }
        case .put(let zone, let name, let type, let fields):
            lock.withLock {
                records[zone, default: [:]][name] = Record(type: type, fields: fields)
                dirty[zone, default: []].insert(name)
            }
        case .delete(let zone, let name):
            lock.withLock {
                records[zone]?[name] = nil
                dirty[zone, default: []].insert(name)
            }
        case .respond(let zone, let name, let response):
            respond(zone: zone, name: name, response: response)
        case .pace(let quick):
            lock.withLock { self.quick = quick }
        case .account:
            Task { await account() }
        case .watchRendezvous(let name, let until):
            rendezvous?.cancel()
            rendezvous = Task { await watch(name, until: Date(timeIntervalSince1970: TimeInterval(until) / 1000)) }
        case .stopRendezvous:
            rendezvous?.cancel()
            rendezvous = nil
        case .join(let url):
            Task { await join(url) }
        }
        poke()
    }

    // MARK: The loop

    private func run() async {
        while true {
            for (zone, link) in lock.withLock({ links }) {
                let full = lock.withLock { fresh.remove(zone) != nil || tokens[zone] == nil }
                do {
                    if full { lock.withLock { tokens[zone] = nil } }
                    let items = try await pull(zone, link)
                    try await push(zone, link, full: full, existing: items)
                } catch {
                    emit(.log(message: "relay: \(zone) of \(link.zoneID.ownerName.prefix(10)): \(error)"))
                    let code = (error as? CKError)?.code
                    if code == .zoneNotFound || code == .userDeletedZone {
                        lock.withLock { links[zone] = nil; records[zone] = nil; dirty[zone] = nil }
                        emit(.unlinked(zone: zone))
                    } else {
                        lock.withLock { _ = fresh.insert(zone) }
                    }
                }
            }
            await sleep(seconds: lock.withLock { quick } ? 1 : 30)
        }
    }

    /// Writes what changed (or everything) and deletes records nobody wants any more.
    /// `existing`: on a full pass, every item record in the zone.
    private func push(_ zone: String, _ link: Link, full: Bool, existing: [CKRecord.ID]) async throws {
        let db = database(link)
        let (wantedRecords, names) = lock.withLock { () -> ([String: Record], Set<String>) in
            defer { dirty[zone] = [] }
            return (records[zone] ?? [:], dirty[zone] ?? [])
        }
        var save: [CKRecord] = []
        var delete: [CKRecord.ID] = []
        for name in full ? Set(wantedRecords.keys) : names {
            let id = CKRecord.ID(recordName: name, zoneID: link.zoneID)
            if let wanted = wantedRecords[name] {
                let record = CKRecord(recordType: wanted.type, recordID: id)
                for (field, value) in wanted.fields { record.encryptedValues[field] = value }
                save.append(record)
            } else {
                delete.append(id)
            }
        }
        if full {
            // Items left over from before the daemon (re)started go.
            delete += existing.filter { wantedRecords[$0.recordName] == nil }
        }
        guard !save.isEmpty || !delete.isEmpty else { return }
        let (saved, deleted) = try await db.modifyRecords(saving: save, deleting: delete, savePolicy: .allKeys, atomically: false)
        // A record written under an earlier membership of the share can't be overwritten: its
        // keys went with that membership. Delete it and write it afresh under this one.
        var stale: [CKRecord.ID] = []
        for case (let id, .failure(let error)) in saved {
            guard (error as? CKError)?.code == .internalError else { throw Failure.record(id.recordName, error) }
            stale.append(id)
        }
        if !stale.isEmpty {
            emit(.log(message: "relay: \(zone): rewriting \(stale.map(\.recordName)) written under an earlier membership"))
            _ = try await db.modifyRecords(saving: [], deleting: stale)
            let again = save.filter { stale.contains($0.recordID) }.map(Self.fresh)
            let (resaved, _) = try await db.modifyRecords(saving: again, deleting: [], savePolicy: .allKeys)
            for case (let id, .failure(let error)) in resaved { throw Failure.record(id.recordName, error) }
        }
        for case (let id, .failure(let error)) in deleted where (error as? CKError)?.code != .unknownItem {
            throw Failure.record(id.recordName, error)
        }
    }

    /// Reports new unanswered inbox records. Returns the item records among the changes: all
    /// of them when the zone had no change token.
    private func pull(_ zone: String, _ link: Link) async throws -> [CKRecord.ID] {
        let db = database(link)
        var token = lock.withLock { tokens[zone] }
        var items: [CKRecord.ID] = []
        var more = true
        while more {
            let changes = try await db.recordZoneChanges(inZoneWith: link.zoneID, since: token)
            for case (let id, .success(let change)) in changes.modificationResultsByID {
                let record = change.record
                switch record.recordType {
                case CloudFeed.Inbox.type:
                    guard record.encryptedValues[CloudFeed.Inbox.response] as? String == nil,
                          let message = record.encryptedValues[CloudFeed.Inbox.message] as? String,
                          lock.withLock({ reported[zone, default: []].insert(id.recordName).inserted }) else { continue }
                    emit(.inbox(zone: zone, name: id.recordName, message: message))
                case CloudFeed.Item.type:
                    items.append(id)
                default:
                    break
                }
            }
            token = changes.changeToken
            more = changes.moreComing
        }
        lock.withLock { tokens[zone] = token }
        return items
    }

    private func respond(zone: String, name: String, response: String) {
        guard let link = lock.withLock({ links[zone] }) else { return }
        let db = database(link)
        Task {
            do {
                let record = try await db.record(for: CKRecord.ID(recordName: name, zoneID: link.zoneID))
                record.encryptedValues[CloudFeed.Inbox.response] = response
                _ = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
            } catch {
                emit(.log(message: "relay: couldn't answer \(name.prefix(8)): \(error)"))
            }
            poke()
        }
    }

    // MARK: Pairing

    private func account() async {
        do {
            emit(.account(user: try await container.userRecordID().recordName, error: nil))
        } catch {
            emit(.account(user: nil, error: "\(error)"))
        }
    }

    /// Polls the public database for the phone's sealed invitation.
    private func watch(_ name: String, until deadline: Date) async {
        let id = CKRecord.ID(recordName: name)
        var lastError = ""
        while Date() < deadline, !Task.isCancelled {
            do {
                let record = try await container.publicCloudDatabase.record(for: id)
                emit(.rendezvous(name: name, sealed: record[CloudFeed.Rendezvous.sealed] as? Data ?? Data()))
                return
            } catch let error as CKError where error.code == .unknownItem {
                // Not written yet.
            } catch {
                // Anything else is worth seeing, once per kind.
                let text = "\(error)"
                if text != lastError { emit(.log(message: "relay: reading the public database: \(text)")) }
                lastError = text
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if !Task.isCancelled { emit(.rendezvous(name: name, sealed: nil)) }
    }

    private func join(_ url: URL) async {
        do {
            let metadata = try await container.shareMetadata(for: url)
            // Joining through an open link would mean anyone holding it could too.
            guard metadata.share.publicPermission == .none else {
                return emit(.joined(zone: nil, owner: nil, error: "the phone's share is open to anyone with its link"))
            }
            _ = try await container.accept(metadata)
            let zoneID = metadata.share.recordID.zoneID
            emit(.joined(zone: zoneID.zoneName, owner: zoneID.ownerName, error: nil))
        } catch {
            emit(.joined(zone: nil, owner: nil, error: "\(error)"))
        }
    }

    // MARK: Helpers

    private enum Failure: Error, CustomStringConvertible {
        case record(String, Error)
        var description: String {
            switch self { case .record(let name, let error): return "record \(name.prefix(12)): \(error)" }
        }
    }

    private func database(_ link: Link) -> CKDatabase {
        link.shared ? container.sharedCloudDatabase : container.privateCloudDatabase
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

    /// The same record, unsaved, so it's created anew rather than updated.
    private static func fresh(_ record: CKRecord) -> CKRecord {
        let copy = CKRecord(recordType: record.recordType, recordID: record.recordID)
        for key in record.encryptedValues.allKeys() { copy.encryptedValues[key] = record.encryptedValues[key] }
        return copy
    }
}
