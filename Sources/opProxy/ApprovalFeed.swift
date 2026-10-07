import CryptoKit

import Foundation
import OpProxyCore

/// One change to the feed's state, in the order consumers must apply them (APPROVAL_FEED.md).
enum FeedMessage {
    case hello(pairedKeys: [String])
    case status([String: Any])
    case upsert(id: String, item: [String: Any])
    case remove(id: String, note: String)

    /// The message as APPROVAL_FEED.md writes it.
    var json: [String: Any] {
        switch self {
        case .hello(let keys): return ["type": "hello", "protocol": 1, "provider": "opProxy", "pairedKeys": keys]
        case .status(let status): return ["type": "status", "status": status]
        case .upsert(_, let item): return ["type": "upsert", "item": item]
        case .remove(let id, let note): return ["type": "remove", "id": id, "note": note]
        }
    }
}

/// Everything a consumer that just connected needs, before any later `FeedMessage`.
struct FeedState {
    let pairedKeys: [String]
    let status: [String: Any]?
    /// Pending items, oldest first.
    let items: [(id: String, item: [String: Any])]
}

/// Carries the feed to phones and their replies back. The feed calls `attach` once, then
/// `send` for every change; both on the feed's queue, so a transport that reads
/// `feed.state()` inside `attach` or `send` sees exactly the state that message produced.
protocol FeedTransport: AnyObject {
    func attach(_ feed: ApprovalFeed) throws
    func send(_ message: FeedMessage)
}

/// Publishes pending approvals so a paired phone can show and answer them (APPROVAL_FEED.md
/// is the protocol), over every transport it is given. Transports only relay, and anything
/// running as you can reach at least one of them, so a reply counts only if a paired phone's
/// key signed it, for a request and a document this feed actually published. All state lives
/// on `queue`.
final class ApprovalFeed {
    /// Offers a phone's decision; false if the request was already decided elsewhere.
    typealias Decide = (Decision) -> Bool
    /// Asks the user, on the Mac, whether to pair a phone. `done` gets nil once it is paired,
    /// or the reason it wasn't.
    typealias ConfirmPairing = (_ name: String, _ publicKey: Data, _ done: @escaping (String?) -> Void) -> Void

    private let log: Log
    private let devices: PairedDeviceStore
    private let confirmPairing: ConfirmPairing
    let queue = DispatchQueue(label: "opProxy.feed")
    private var transports: [FeedTransport] = []
    private var items: [String: Item] = [:]
    /// Notes for items no longer pending, so a late reply hears why.
    private var finished: [String: String] = [:]
    private var pairing = false
    private var announcedKeys: [String] = []
    private var keyWatch: DispatchSourceTimer?
    /// The 1Password authorization and whether its prompt may be up; set before `start()`.
    var authStatus: (() -> (window: AuthWindow, prompting: Bool))?
    private var status: FeedStatus?
    private var lostSince = Date()

    private struct Item {
        let id: String
        let key: DialogKey
        let prompt: ApprovalPrompt
        let options: [ApprovalOption]
        let defaultIndex: Int
        let createdAt: Date
        var expiresAt: Date?
        let challenge: String
        /// Option ID → the approval times its challenge grant commits to.
        let grants: [String: (approvedAt: Date, expiresAt: Date)]
        let decide: Decide
        var abandoned = false
        var revision = 0
        /// The current revision's document, as the exact string sent.
        var document = ""
        /// SHA-256 of every revision's document: a reply may answer any of them.
        var documentHashes: Set<String> = []
    }

    init(log: Log, devices: PairedDeviceStore, confirmPairing: @escaping ConfirmPairing) {
        self.log = log
        self.devices = devices
        self.confirmPairing = confirmPairing
    }

    /// Starts each transport that attaches; one that can't is logged and left out.
    func start(_ transports: [FeedTransport]) {
        queue.sync {
            announcedKeys = pairedKeys()
            for transport in transports {
                do {
                    try transport.attach(self)
                    self.transports.append(transport)
                } catch {
                    log.write("approval feed: \(type(of: transport)) didn't start: \(error)")
                }
            }
        }
        // `opProxy unpair` edits the file from another process; tell consumers when keys change.
        // The authorization is polled here too, which also catches it passing the 12-hour cap.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.announceKeysIfChanged()
            self?.announceStatusIfChanged()
        }
        timer.resume()
        keyWatch = timer
    }

    /// The feed as it stands; call on `queue`.
    func state() -> FeedState {
        dispatchPrecondition(condition: .onQueue(queue))
        announceKeysIfChanged()
        announceStatusIfChanged()
        return FeedState(pairedKeys: announcedKeys, status: status?.json,
                         items: items.values.sorted { $0.createdAt < $1.createdAt }.map { ($0.id, json($0)) })
    }

    /// A message from a consumer. `respond` gets the `reply-result` or `pair-result` to send
    /// back, on `queue`; other messages get no response.
    func receive(_ message: [String: Any], respond: @escaping ([String: Any]) -> Void) {
        queue.async { [self] in
            switch message["type"] as? String {
            case "reply":
                let error = handleReply(message)
                if let error { log.write("phone reply refused: \(error)") }
                var reply: [String: Any] = ["type": "reply-result", "id": message["id"] as? String ?? "", "ok": error == nil]
                if let error { reply["error"] = error }
                respond(reply)
            case "pair":
                handlePair(message, respond: respond)
            default:
                break
            }
        }
    }

    // MARK: Requests

    /// Publishes `prompt`; returns its item ID. `decide` is called on the feed's queue.
    func publish(_ prompt: ApprovalPrompt, decide: @escaping Decide) -> String {
        let id = Self.random(16)
        queue.async { [self] in
            let (options, defaultIndex) = ApprovalOptions.for(prompt.requester)
            // Each lasting option's grant is the exact approval it would store, fixed now so
            // the phone's signature can commit to it.
            let approvedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            var grants: [String: (approvedAt: Date, expiresAt: Date)] = [:]
            var hashes: [String: String] = [:]
            if case .agent(let key) = prompt.key {
                for option in options {
                    guard case .lasting(let lifetime, _) = option.scope, let stored = option.scope.storedKey(for: key) else { continue }
                    let expiresAt = lifetime.expiry(from: approvedAt)
                    grants[option.id] = (approvedAt, expiresAt)
                    hashes[option.id] = sha256Hex(Approval.payload(key: stored, approvedAt: approvedAt, expiresAt: expiresAt))
                }
            }
            let challenge = ApprovalChallenge(nonce: Self.random(18), picker: RemoteCard.picker, grants: hashes)
            var item = Item(id: id, key: prompt.key, prompt: prompt, options: options, defaultIndex: defaultIndex,
                            createdAt: Date(), challenge: challenge.encoded, grants: grants, decide: decide)
            revise(&item)
            items[id] = item
            broadcast(.upsert(id: item.id, item: json(item)))
        }
        return id
    }

    /// `key`'s dialog is on screen and times out at `deadline`.
    func countdown(_ key: DialogKey, until deadline: Date) {
        queue.async { [self] in
            guard var item = items.values.first(where: { $0.key == key }) else { return }
            item.expiresAt = deadline
            items[item.id] = item
            broadcast(.upsert(id: item.id, item: json(item)))
        }
    }

    func requestersLeft(_ key: DialogKey) {
        queue.async { [self] in
            guard var item = items.values.first(where: { $0.key == key }), !item.abandoned else { return }
            item.abandoned = true
            revise(&item)
            items[item.id] = item
            broadcast(.upsert(id: item.id, item: json(item)))
        }
    }

    /// Decided on the Mac, or timed out.
    func remove(_ id: String, note: String) {
        queue.async { [self] in finish(id, note: note) }
    }

    private func finish(_ id: String, note: String) {
        guard items.removeValue(forKey: id) != nil else { return }
        finished[id] = note
        broadcast(.remove(id: id, note: note))
    }

    /// A new document revision; the item's earlier documents stay answerable.
    private func revise(_ item: inout Item) {
        item.revision += 1
        item.document = RemoteCard.document(item.prompt, options: item.options, defaultIndex: item.defaultIndex,
                                            abandoned: item.abandoned)
        item.documentHashes.insert(sha256Hex(Data(item.document.utf8)))
    }

    // MARK: Replies

    private func handleReply(_ message: [String: Any]) -> String? {
        let id = message["id"] as? String ?? ""
        guard let keyId = message["keyId"] as? String, let text = message["statement"] as? String,
              let signature = (message["signature"] as? String).flatMap({ Data(base64Encoded: $0) })
        else { return "That reply was malformed." }
        guard let device = devices.device(keyId: keyId) else { return "This phone isn't paired with opProxy." }
        guard DeviceKey.verify(Data(text.utf8), signature: signature, rawPublicKey: device.publicKey) else {
            return "The reply's signature didn't verify."
        }
        guard let statement = ApprovalStatement.parse(text), statement.v == 1, statement.provider == "opProxy",
              statement.keyId == keyId, statement.id == id
        else { return "That reply was malformed." }
        guard let item = items[id] else {
            switch finished[id] {
            case nil: return "That request is no longer pending."
            case "Timed out": return "That request timed out."
            default: return "That request was already answered."
            }
        }
        guard statement.challenge == item.challenge else { return "That reply is for a different request." }
        guard item.documentHashes.contains(statement.documentSha256) else {
            return "The phone's copy of this request isn't one opProxy sent."
        }
        for (picker, choice) in statement.picks where picker != RemoteCard.picker || !item.options.contains(where: { $0.id == choice }) {
            return "That option wasn't offered."
        }
        let decision: Decision
        let pick = statement.picks[RemoteCard.picker]
        switch statement.action {
        case "deny":
            decision = .denied
        case "approve":
            guard let option = item.options.first(where: { $0.id == pick }) else { return "Choose what to allow." }
            let proof = DeviceProof(keyId: keyId, statement: text, signature: signature)
            decision = .approved(.device(proof, grant: item.grants[option.id]), option.scope)
        default:
            return "That action wasn't offered."
        }
        guard item.decide(decision) else { return "That request was already answered." }
        let approved = statement.action == "approve"
        log.write("phone \(statement.action)\(approved ? " " + (pick ?? "") : ""): \(device.name) (\(keyId.prefix(8))) item \(id.prefix(8))")
        finish(id, note: approved ? "Approved on the phone" : "Denied on the phone")
        return nil
    }

    // MARK: Pairing

    private func handlePair(_ message: [String: Any], respond: @escaping ([String: Any]) -> Void) {
        func result(_ keyId: String, _ error: String?) {
            var reply: [String: Any] = ["type": "pair-result", "keyId": keyId, "ok": error == nil]
            if let error { reply["error"] = error }
            respond(reply)
        }
        guard let raw = (message["publicKey"] as? String).flatMap({ Data(base64Encoded: $0) }), raw.count == 64,
              (try? P256.Signing.PublicKey(rawRepresentation: raw)) != nil
        else { return result("", "That isn't a P-256 public key.") }
        let keyId = DeviceKey.keyId(rawPublicKey: raw)
        let trimmed = ((message["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Phone" : String(trimmed.prefix(60))
        if devices.device(keyId: keyId) != nil { return result(keyId, nil) }
        guard !pairing else { return result(keyId, "Another phone is waiting to be paired on the Mac.") }
        pairing = true
        log.write("pairing requested: \(name) \(DeviceKey.fingerprint(keyId: keyId))")
        confirmPairing(name, raw) { [self] error in
            queue.async { [self] in
                pairing = false
                log.write(error.map { "pairing refused: \(name): \($0)" } ?? "paired: \(name) \(DeviceKey.fingerprint(keyId: keyId))")
                result(keyId, error)
                announceKeysIfChanged()
            }
        }
    }

    private func pairedKeys() -> [String] { devices.devices.map(\.keyId) }

    private func announceKeysIfChanged() {
        let keys = pairedKeys()
        guard keys != announcedKeys else { return }
        announcedKeys = keys
        broadcast(.hello(pairedKeys: keys))
    }

    // MARK: Status

    private func announceStatusIfChanged() {
        guard let authStatus else { return }
        let (window, prompting) = authStatus()
        let now = Date()
        if status?.ok == true, window.remaining(at: now) == nil { lostSince = now }
        let next = FeedStatus(window, prompting: prompting, lostSince: lostSince, now: now)
        guard next != status else { return }
        status = next
        broadcast(.status(next.json))
    }

    private func broadcast(_ message: FeedMessage) {
        for transport in transports { transport.send(message) }
    }

    private func json(_ item: Item) -> [String: Any] {
        func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
        return ["id": item.id, "revision": item.revision, "createdAt": ms(item.createdAt),
                "expiresAt": item.expiresAt.map(ms) ?? NSNull(), "challenge": item.challenge, "document": item.document]
    }

    private static func random(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
