import CryptoKit
import Foundation
import OpProxyCore

/// A paired iPhone's zone that opProxy iCloud Relay serves for this Mac.
struct RelayLink: Codable, Equatable {
    let zone: String
    /// The zone owner's record name; empty when the phone shares the Mac's Apple ID.
    let owner: String
    /// The zone is the phone's, on another Apple ID, so it's in the Mac's shared database.
    let shared: Bool
    /// The paired phone's device key and the 1Password item with the pairing secret, once
    /// pairing has finished.
    var keyId: String?
    var keyItem: String?
    let linkedAt: Date
}

/// Carries the approval feed to paired iPhones through opProxy iCloud Relay, the separately
/// signed helper that holds CloudKit. The relay runs as this daemon's child only while there
/// is a phone (or a pairing) to serve. Every field is sealed here with that pairing's key
/// (`SealedField`), and every phone write is opened here, so the relay only ever moves
/// ciphertext. Pairing keys live in 1Password (`PairingKeyVault`) and are read back once the
/// session is authorized. All state lives on `queue`.
final class RelayTransport: FeedTransport {
    /// Where the relay is: inside this app (releases), beside it (install.sh), or in
    /// Applications (downloaded separately). `OPPROXY_RELAY` overrides it in test builds.
    static func locate() -> URL? {
        if let path = TestKnobs.value("OPPROXY_RELAY") { return URL(fileURLWithPath: path) }
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [app.appendingPathComponent("Contents/Helpers"), app.deletingLastPathComponent(),
                          URL(fileURLWithPath: "/Applications")]
        return candidates.map { $0.appendingPathComponent("\(appName).app/Contents/MacOS/opProxyRelay") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static let appName = "opProxy iCloud Relay"

    /// How long a phone's inbox message stays acceptable after it was sealed.
    static let inboxLifetime: TimeInterval = 600

    private let log: Log
    private let linksURL: URL
    private let vault: PairingKeyVault
    private let devices: PairedDeviceStore
    private let identity: () -> MacIdentity
    /// Whether 1Password has authorized the session, so pairing keys can be read.
    private let authorized: () -> Bool
    private let queue = DispatchQueue(label: "opProxy.relay")
    private weak var feed: ApprovalFeed?
    private var links: [RelayLink] = []
    private var keys: [String: PairingKey] = [:]
    private var loading: [String: Date] = [:]
    private var mirror = Mirror()
    private var relay: (process: Process, input: FileHandle)?
    private var relayExitedAt = Date.distantPast
    private var paced: Bool?
    private var presenceWritten = Date.distantPast
    private var timer: DispatchSourceTimer?
    private var pairing: PairingSession?

    /// What the zones should hold. Record name → JSON string; removed items keep their note
    /// for a while so a phone can say why one disappeared.
    private struct Mirror {
        var items: [String: (item: String, note: String?, removedAt: Date?)] = [:]
        var state: [String: String] = [:]
        var pending: Bool { items.values.contains { $0.note == nil } }
    }

    init(linksURL: URL, vault: PairingKeyVault, devices: PairedDeviceStore, identity: @escaping () -> MacIdentity,
         authorized: @escaping () -> Bool, log: Log) {
        self.linksURL = linksURL
        self.vault = vault
        self.devices = devices
        self.identity = identity
        self.authorized = authorized
        self.log = log
        links = (try? JSONDecoder().decode([RelayLink].self, from: Data(contentsOf: linksURL))) ?? []
    }

    func attach(_ feed: ApprovalFeed) throws {
        self.feed = feed
        let state = feed.state()
        queue.sync {
            mirror.state[CloudFeed.State.hello] = Self.string(FeedMessage.hello(pairedKeys: state.pairedKeys, mac: state.mac).json)
            mirror.state[CloudFeed.State.presence] = Self.presence()
            if let status = state.status { mirror.state[CloudFeed.State.status] = Self.string(FeedMessage.status(status).json) }
            for (id, item) in state.items { mirror.items[id] = (Self.string(item), nil, nil) }
        }
        log.write("relay feed: \(links.count) linked phone zone(s)")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 5)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func send(_ message: FeedMessage) {
        queue.async { [self] in
            let name: String
            switch message {
            case .hello:
                name = CloudFeed.State.hello
                mirror.state[name] = Self.string(message.json)
            case .status:
                name = CloudFeed.State.status
                mirror.state[name] = Self.string(message.json)
            case .upsert(let id, let item):
                name = id
                mirror.items[id] = (Self.string(item), nil, nil)
            case .remove(let id, let note):
                guard let old = mirror.items[id] else { return }
                name = id
                mirror.items[id] = (old.item, note, Date())
            }
            for link in links where keys[link.zone] != nil { put(name, in: link.zone) }
            pace()
        }
    }

    // MARK: Housekeeping

    /// Every 5 seconds: keeps the relay running while it's needed, reads pairing keys once
    /// 1Password allows, drops links whose phone was unpaired, and refreshes presence.
    private func tick() {
        reconcile()
        let needed = !links.isEmpty || pairing != nil
        if needed, relay == nil, Date().timeIntervalSince(relayExitedAt) > 10 { startRelay() }
        if !needed, let relay {
            log.write("relay feed: stopping the relay: no phone to serve")
            try? relay.input.close()
            self.relay = nil
        }
        loadKeys()
        prune()
        if mirror.pending, Date().timeIntervalSince(presenceWritten) >= CloudFeed.State.presenceInterval {
            presenceWritten = Date()
            mirror.state[CloudFeed.State.presence] = Self.presence()
            for link in links where keys[link.zone] != nil { put(CloudFeed.State.presence, in: link.zone) }
        }
        pace()
    }

    /// Links whose phone is no longer paired, and pairings that never finished, go, along
    /// with their keys in 1Password.
    private func reconcile() {
        let paired = Set(devices.devices.map(\.keyId))
        for link in links {
            let unpaired = link.keyId.map { !paired.contains($0) } ?? (pairing?.zone != link.zone)
            if unpaired { drop(link.zone, because: link.keyId == nil ? "pairing didn't finish" : "its phone was unpaired") }
        }
    }

    private func drop(_ zone: String, because reason: String) {
        guard let link = links.first(where: { $0.zone == zone }) else { return }
        log.write("relay feed: dropping zone \(zone.prefix(13)): \(reason)")
        links.removeAll { $0.zone == zone }
        keys[zone] = nil
        saveLinks()
        command(.unlink(zone: zone))
        if let item = link.keyItem {
            DispatchQueue.global().async { [vault, log] in
                do { try vault.delete(itemId: item) } catch { log.write("relay feed: \(error)") }
            }
        }
    }

    private func loadKeys() {
        guard authorized() else { return }
        for link in links where keys[link.zone] == nil {
            guard let item = link.keyItem, Date().timeIntervalSince(loading[link.zone] ?? .distantPast) > 30 else { continue }
            loading[link.zone] = Date()
            DispatchQueue.global().async { [self] in
                let result = Result { try vault.load(itemId: item, commitment: nil) }
                queue.async { [self] in
                    switch result {
                    case .success(let key):
                        guard links.contains(where: { $0.zone == link.zone && $0.keyItem == item }) else { return }
                        keys[link.zone] = key
                        log.write("relay feed: read the pairing key for zone \(link.zone.prefix(13))")
                        serve(link)
                    case .failure(let error):
                        log.write("relay feed: zone \(link.zone.prefix(13)): \(error)")
                    }
                }
            }
        }
    }

    /// Removed items are forgotten after 10 minutes, and their records deleted.
    private func prune() {
        let cutoff = Date() - 600
        for (id, item) in mirror.items where (item.removedAt ?? .distantFuture) < cutoff {
            mirror.items[id] = nil
            for link in links where keys[link.zone] != nil { command(.delete(zone: link.zone, name: id)) }
        }
    }

    private func pace() {
        let quick = mirror.pending || pairing != nil
        guard quick != paced, relay != nil else { return }
        paced = quick
        command(.pace(quick: quick))
    }

    // MARK: Records

    /// Tells the relay to serve `link`'s zone, with everything it should hold.
    private func serve(_ link: RelayLink) {
        command(.link(zone: link.zone, owner: link.owner, shared: link.shared))
        guard keys[link.zone] != nil else {
            // Not paired yet, so nothing can be sealed: the phone only needs to see that the
            // Mac joined, which an empty hello shows. (Paired, but its key not read back yet:
            // the zone keeps what it has until it is.)
            if link.keyItem == nil {
                command(.put(zone: link.zone, name: CloudFeed.State.hello, type: CloudFeed.State.type,
                             fields: [CloudFeed.State.message: ""]))
            }
            return
        }
        for name in mirror.state.keys { put(name, in: link.zone) }
        for name in mirror.items.keys { put(name, in: link.zone) }
    }

    private func put(_ name: String, in zone: String) {
        guard let key = keys[zone] else { return }
        do {
            if let state = mirror.state[name] {
                let message = try SealedField.seal(state, with: key, recordType: CloudFeed.State.type, field: CloudFeed.State.message,
                                                   recordName: name, from: .mac)
                command(.put(zone: zone, name: name, type: CloudFeed.State.type, fields: [CloudFeed.State.message: message]))
            } else if let item = mirror.items[name] {
                var fields = [CloudFeed.Item.item: try SealedField.seal(item.item, with: key, recordType: CloudFeed.Item.type,
                                                                        field: CloudFeed.Item.item, recordName: name, from: .mac)]
                if let note = item.note {
                    fields[CloudFeed.Item.note] = try SealedField.seal(note, with: key, recordType: CloudFeed.Item.type,
                                                                       field: CloudFeed.Item.note, recordName: name, from: .mac)
                }
                command(.put(zone: zone, name: name, type: CloudFeed.Item.type, fields: fields))
            } else {
                command(.delete(zone: zone, name: name))
            }
        } catch {
            log.write("relay feed: couldn't seal \(name.prefix(8)): \(error)")
        }
    }

    // MARK: The relay process

    private func startRelay() {
        guard let executable = Self.locate() else {
            if relayExitedAt != .distantFuture { log.write("relay feed: \(Self.appName) isn't installed, so phones can't be reached") }
            relayExitedAt = .distantFuture
            return
        }
        let process = Process()
        process.executableURL = executable
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        var buffer = Data()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            buffer += chunk
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                guard let event = RelayLine.decode(RelayEvent.self, line) else { continue }
                self?.queue.async { self?.handle(event) }
            }
        }
        process.terminationHandler = { [weak self] ended in
            self?.queue.async { [weak self] in
                guard let self, self.relay?.process === ended else { return }
                self.log.write("relay feed: the relay exited (\(ended.terminationStatus))")
                self.relay = nil
                self.relayExitedAt = Date()
            }
        }
        do {
            try process.run()
        } catch {
            log.write("relay feed: couldn't start \(executable.path): \(error)")
            relayExitedAt = Date()
            return
        }
        relay = (process, input.fileHandleForWriting)
        paced = nil
        log.write("relay feed: started \(Self.appName) (\(process.processIdentifier))")
    }

    private func command(_ command: RelayCommand) {
        guard let relay else { return }
        do { try relay.input.write(contentsOf: RelayLine.encode(command)) } catch {
            log.write("relay feed: couldn't reach the relay: \(error)")
        }
    }

    private func handle(_ event: RelayEvent) {
        switch event {
        case .ready(let version, let protocolVersion):
            guard protocolVersion == RelayProtocol.version else {
                // Not retried until opProxy restarts or pairing starts again: a different relay
                // has to be installed first.
                let older = protocolVersion < RelayProtocol.version ? "\(Self.appName)" : "this opProxy"
                let message = "\(Self.appName) \(version) speaks relay protocol \(protocolVersion), and this opProxy "
                    + "speaks \(RelayProtocol.version), so phones can't be reached. Update \(older)."
                log.write("relay feed: \(message)")
                try? relay?.input.close()
                relay = nil
                relayExitedAt = .distantFuture
                pairing?.finish(ok: false, message, self)
                return
            }
            log.write("relay feed: relay \(version) ready (protocol \(protocolVersion))")
            paced = nil
            pace()
            for link in links { serve(link) }
            if let pairing { pairing.resume(self) }
        case .log(let text):
            log.write(text)
        case .unlinked(let zone):
            drop(zone, because: "the phone removed it")
        case .inbox(let zone, let name, let message):
            receive(message, zone: zone, name: name)
        case .account(let user, let error):
            pairing?.account(user: user, error: error, self)
        case .rendezvous(let name, let sealed):
            pairing?.rendezvous(name: name, sealed: sealed, self)
        case .joined(let zone, let owner, let error):
            pairing?.joined(zone: zone, owner: owner, error: error, self)
        }
    }

    private func receive(_ message: String, zone: String, name: String) {
        guard let link = links.first(where: { $0.zone == zone }) else { return }
        guard let key = keys[zone] else {
            if link.keyItem == nil, let pairing, pairing.zone == zone { pairing.inbox(message, name: name, self) }
            return
        }
        guard let text = try? SealedField.open(message, with: key, recordType: CloudFeed.Inbox.type, field: CloudFeed.Inbox.message,
                                               recordName: name, from: .phone, maxAge: Self.inboxLifetime, now: Date()),
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return log.write("relay feed: zone \(zone.prefix(13)): an inbox message didn't open") }
        feed?.receive(json) { [self] response in
            queue.async { [self] in
                guard let key = keys[zone], let sealed = try? SealedField.seal(Self.string(response), with: key, recordType: CloudFeed.Inbox.type,
                                                                              field: CloudFeed.Inbox.response, recordName: name, from: .mac)
                else { return }
                command(.respond(zone: zone, name: name, response: sealed))
            }
        }
    }

    private func saveLinks() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(links).write(to: linksURL, options: .atomic)
    }

    private static func presence() -> String {
        string(["type": "presence", "aliveAt": Int64(Date().timeIntervalSince1970 * 1000)])
    }

    static func string(_ json: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]),
               as: UTF8.self)
    }

    // MARK: Pairing

    /// What pairing shows: the QR code to scan, progress, and how it ended.
    enum PairingUpdate {
        case code(String)
        case progress(String)
        case finished(ok: Bool, String)
    }

    /// Shows a pairing code and waits up to 10 minutes for a phone. `update` is called on the
    /// main thread.
    func startPairing(_ update: @escaping (PairingUpdate) -> Void) {
        queue.async { [self] in
            pairing?.cancel(self)
            let session = PairingSession(update: { change in DispatchQueue.main.async { update(change) } })
            pairing = session
            if Self.locate() == nil {
                return session.finish(ok: false, "Pairing an iPhone needs \(Self.appName). Download it from opProxy's "
                                      + "GitHub releases and put it in Applications.", self)
            }
            if relay == nil { relayExitedAt = .distantPast; startRelay() } else { session.resume(self) }
            pace()
        }
    }

    func cancelPairing() {
        queue.async { [self] in pairing?.cancel(self) }
    }

    /// One pairing, from showing the code to the phone holding the pairing key. It runs on the
    /// transport's queue.
    private final class PairingSession {
        let update: (PairingUpdate) -> Void
        let code = CloudFeed.Rendezvous.newCode()
        let agreementKey = Curve25519.KeyAgreement.PrivateKey()
        let deadline = Date() + 600
        var zone: String { CloudFeed.Rendezvous.zoneName(code: code) }
        private var asked = false
        private var linked = false
        private var answering = false

        init(update: @escaping (PairingUpdate) -> Void) {
            self.update = update
        }

        /// The relay is (newly) running: ask for this Mac's iCloud user, or pick up where the
        /// pairing was.
        func resume(_ t: RelayTransport) {
            if linked { return }
            if asked { return t.command(.watchRendezvous(name: CloudFeed.Rendezvous.recordName(code: code), until: ms(deadline))) }
            t.command(.account)
        }

        func account(user: String?, error: String?, _ t: RelayTransport) {
            guard !asked else { return }
            guard let user else { return finish(ok: false, "iCloud isn't available on this Mac: \(error ?? "unknown")", t) }
            asked = true
            let mac = t.identity()
            t.log.write("phone pairing: showing the code for iCloud user \(user.prefix(10))")
            update(.code(CloudFeed.Rendezvous.qrPayload(code: code, macUser: user, macID: mac.id,
                                                        agreementKey: agreementKey.publicKey.rawRepresentation)))
            t.command(.watchRendezvous(name: CloudFeed.Rendezvous.recordName(code: code), until: ms(deadline)))
        }

        func rendezvous(name: String, sealed: Data?, _ t: RelayTransport) {
            guard name == CloudFeed.Rendezvous.recordName(code: code), !linked else { return }
            guard let sealed else { return finish(ok: false, "timed out", t) }
            guard let invitation = CloudFeed.Rendezvous.open(sealed, code: code) else {
                return finish(ok: false, "the phone's reply didn't open", t)
            }
            switch invitation {
            case .ownZone(let name):
                guard name == zone else { return finish(ok: false, "the phone named a zone this code didn't", t) }
                link(owner: "", shared: false, t)
            case .share(let url):
                update(.progress("Joining the phone's zone…"))
                t.command(.join(share: url))
            }
        }

        func joined(zone joinedZone: String?, owner: String?, error: String?, _ t: RelayTransport) {
            guard !linked else { return }
            guard let joinedZone, let owner else { return finish(ok: false, error ?? "couldn't join the phone's zone", t) }
            guard joinedZone == zone else { return finish(ok: false, "the phone shared a zone this code didn't name", t) }
            link(owner: owner, shared: true, t)
        }

        private func link(owner: String, shared: Bool, _ t: RelayTransport) {
            linked = true
            let link = RelayLink(zone: zone, owner: owner, shared: shared, keyId: nil, keyItem: nil, linkedAt: Date())
            t.links.removeAll { $0.zone == zone }
            t.links.append(link)
            t.saveLinks()
            t.log.write("relay feed: linked \(shared ? "shared" : "own") zone \(zone.prefix(13)) of \(owner.prefix(10))")
            t.serve(link)
            update(.progress("Joined. Waiting for the phone to ask to be trusted…"))
        }

        /// The phone's `pair` message, unsealed: there's no key yet.
        func inbox(_ text: String, name: String, _ t: RelayTransport) {
            guard !answering, let message = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  message["type"] as? String == "pair" else { return }
            func refuse(_ error: String) {
                respond(["type": "pair-result", "keyId": "", "ok": false, "error": error], name: name, t)
                finish(ok: false, error, t)
            }
            guard let deviceKey = (message["publicKey"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let phoneAgreement = (message[PairingHandshake.agreementKeyField] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let signature = (message[PairingHandshake.agreementSignatureField] as? String).flatMap({ Data(base64Encoded: $0) }),
                  DeviceKey.verify(PairingHandshake.phoneStatement(phoneAgreementKey: phoneAgreement,
                                                                   macAgreementKey: agreementKey.publicKey.rawRepresentation,
                                                                   macID: t.identity().id),
                                   signature: signature, rawPublicKey: deviceKey)
            else { return refuse("This phone's opProxy needs updating to pair with this Mac.") }
            answering = true
            // The feed confirms the phone on the Mac (Touch ID) and pairs its device key.
            t.feed?.receive(message) { [self] response in
                t.queue.async { [self] in
                    guard response["ok"] as? Bool == true, let keyId = response["keyId"] as? String else {
                        respond(response, name: name, t)
                        return finish(ok: false, response["error"] as? String ?? "the Mac refused it", t)
                    }
                    deliverKey(response, keyId: keyId, deviceKey: deviceKey, phoneAgreement: phoneAgreement, signature: signature,
                               phoneName: String((message["name"] as? String ?? "iPhone").prefix(60)), name: name, t)
                }
            }
        }

        /// Makes the pairing key in 1Password and seals it for the phone.
        private func deliverKey(_ response: [String: Any], keyId: String, deviceKey: Data, phoneAgreement: Data, signature: Data,
                                phoneName: String, name: String, _ t: RelayTransport) {
            let mac = t.identity()
            DispatchQueue.global().async { [self] in
                let result = Result { () -> (String, Data, Data) in
                    let (item, secret) = try t.vault.create(phoneName: phoneName, macName: mac.name)
                    let sealed = try PairingHandshake.sealSecret(secret, macKey: agreementKey, phoneAgreementKey: phoneAgreement,
                                                                 phoneSignature: signature, phoneDeviceKey: deviceKey, macID: mac.id)
                    return (item, secret, sealed)
                }
                t.queue.async { [self] in
                    switch result {
                    case .failure(let error):
                        // Paired without a key would be a phone that can't hear anything: undo it.
                        _ = try? t.devices.unpair { $0.keyId == keyId }
                        let text = "Couldn't make the pairing key: \(error)"
                        respond(["type": "pair-result", "keyId": keyId, "ok": false, "error": text], name: name, t)
                        finish(ok: false, text, t)
                    case .success(let (item, secret, sealed)):
                        // A phone pairs with a Mac once: its earlier pairing's zone and key go.
                        for old in t.links where old.keyId == keyId && old.zone != zone { t.drop(old.zone, because: "the phone paired again") }
                        guard let index = t.links.firstIndex(where: { $0.zone == zone }) else { return }
                        t.links[index].keyId = keyId
                        t.links[index].keyItem = item
                        t.saveLinks()
                        t.keys[zone] = PairingKey(secret: secret)
                        var reply = response
                        reply[PairingHandshake.sealedSecretField] = sealed.base64EncodedString()
                        respond(reply, name: name, t)
                        t.serve(t.links[index])
                        finish(ok: true, "Paired. Requests will now reach the phone.", t)
                    }
                }
            }
        }

        private func respond(_ response: [String: Any], name: String, _ t: RelayTransport) {
            t.command(.respond(zone: zone, name: name, response: RelayTransport.string(response)))
        }

        func finish(ok: Bool, _ message: String, _ t: RelayTransport) {
            guard t.pairing === self else { return }
            t.log.write("phone pairing: \(ok ? "paired" : message)")
            t.pairing = nil
            t.command(.stopRendezvous)
            update(.finished(ok: ok, message))
        }

        func cancel(_ t: RelayTransport) {
            guard t.pairing === self else { return }
            t.pairing = nil
            t.command(.stopRendezvous)
        }

        private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
    }
}
