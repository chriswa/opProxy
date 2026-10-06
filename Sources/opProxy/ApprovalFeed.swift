import CryptoKit
import Darwin
import Foundation
import OpProxyCore

/// Publishes pending approvals on `Paths.approvalFeed` so the Spaceterm phone app can show
/// and answer them (APPROVAL_FEED.md is the protocol). Spaceterm only relays, and anything
/// running as you can connect here, so a reply counts only if a paired phone's key signed it,
/// for a request and a document this feed actually published. All state lives on `queue`.
final class ApprovalFeed {
    /// Offers a phone's decision; false if the request was already decided elsewhere.
    typealias Decide = (Decision) -> Bool
    /// Asks the user, on the Mac, whether to pair a phone. `done` gets nil once it is paired,
    /// or the reason it wasn't.
    typealias ConfirmPairing = (_ name: String, _ publicKey: Data, _ done: @escaping (String?) -> Void) -> Void

    private let path: URL
    private let log: Log
    private let devices: PairedDeviceStore
    private let confirmPairing: ConfirmPairing
    private let queue = DispatchQueue(label: "opProxy.feed")
    private var clients: [Int: Int32] = [:]
    private var nextClient = 0
    private var items: [String: Item] = [:]
    /// Notes for items no longer pending, so a late reply hears why.
    private var finished: [String: String] = [:]
    private var pairing = false
    private var announcedKeys: [String] = []
    private var keyWatch: DispatchSourceTimer?

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

    init(path: URL, log: Log, devices: PairedDeviceStore, confirmPairing: @escaping ConfirmPairing) {
        self.path = path
        self.log = log
        self.devices = devices
        self.confirmPairing = confirmPairing
    }

    func start() throws {
        let listener = try UnixSocket.listen(path: path.path)
        log.write("approval feed on \(path.path)")
        queue.sync { announcedKeys = pairedKeys() }
        Thread.detachNewThread { [self] in
            while true {
                let fd = accept(listener, nil, nil)
                if fd < 0 { continue }
                UnixSocket.noSigpipe(fd)
                // A client that stops reading mustn't stall everyone else's updates.
                var tv = timeval(tv_sec: 2, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                serve(fd)
            }
        }
        // `opProxy unpair` edits the file from another process; tell clients when keys change.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.announceKeysIfChanged() }
        timer.resume()
        keyWatch = timer
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
            broadcast(["type": "upsert", "item": json(item)])
        }
        return id
    }

    /// `key`'s dialog is on screen and times out at `deadline`.
    func countdown(_ key: DialogKey, until deadline: Date) {
        queue.async { [self] in
            guard var item = items.values.first(where: { $0.key == key }) else { return }
            item.expiresAt = deadline
            items[item.id] = item
            broadcast(["type": "upsert", "item": json(item)])
        }
    }

    func requestersLeft(_ key: DialogKey) {
        queue.async { [self] in
            guard var item = items.values.first(where: { $0.key == key }), !item.abandoned else { return }
            item.abandoned = true
            revise(&item)
            items[item.id] = item
            broadcast(["type": "upsert", "item": json(item)])
        }
    }

    /// Decided on the Mac, or timed out.
    func remove(_ id: String, note: String) {
        queue.async { [self] in finish(id, note: note) }
    }

    private func finish(_ id: String, note: String) {
        guard items.removeValue(forKey: id) != nil else { return }
        finished[id] = note
        broadcast(["type": "remove", "id": id, "note": note])
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

    private func handlePair(_ message: [String: Any], client: Int) {
        func result(_ keyId: String, _ error: String?) {
            var reply: [String: Any] = ["type": "pair-result", "keyId": keyId, "ok": error == nil]
            if let error { reply["error"] = error }
            send(client, reply)
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

    private func hello() -> [String: Any] {
        ["type": "hello", "protocol": 1, "provider": "opProxy", "pairedKeys": announcedKeys]
    }

    private func announceKeysIfChanged() {
        let keys = pairedKeys()
        guard keys != announcedKeys else { return }
        announcedKeys = keys
        broadcast(hello())
    }

    // MARK: Connections

    private func serve(_ fd: Int32) {
        queue.async { [self] in
            let client = nextClient
            nextClient += 1
            announceKeysIfChanged()
            clients[client] = fd
            send(client, hello())
            send(client, ["type": "snapshot", "items": items.values.sorted { $0.createdAt < $1.createdAt }.map(json)])
            Thread.detachNewThread { [self] in
                let reader = LineReader(fd: fd, limit: 1 << 20)
                while let line = reader.next() {
                    queue.async { [self] in handle(line, client: client) }
                }
                queue.async { [self] in
                    clients.removeValue(forKey: client)
                    close(fd)
                }
            }
        }
    }

    private func handle(_ line: Data, client: Int) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        switch message["type"] as? String {
        case "reply":
            let error = handleReply(message)
            if let error { log.write("phone reply refused: \(error)") }
            var reply: [String: Any] = ["type": "reply-result", "id": message["id"] as? String ?? "", "ok": error == nil]
            if let error { reply["error"] = error }
            send(client, reply)
        case "pair":
            handlePair(message, client: client)
        default:
            break
        }
    }

    private func broadcast(_ message: [String: Any]) {
        for client in clients.keys { send(client, message) }
    }

    /// A failed write drops the client; its reader then sees EOF and cleans up.
    private func send(_ client: Int, _ message: [String: Any]) {
        guard let fd = clients[client],
              let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return }
        if !UnixSocket.writeAll(fd, data + Data("\n".utf8)) { shutdown(fd, SHUT_RDWR) }
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
