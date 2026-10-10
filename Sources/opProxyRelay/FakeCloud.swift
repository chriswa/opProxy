#if OPPROXY_TESTING
import CryptoKit
import FeedProtocol
import Foundation

/// Test builds, with `OPPROXY_TEST_FAKE_CLOUD=<dir>`: a relay with no CloudKit behind it, and a
/// phone that pairs and answers through it, for Tests/relay-integration.sh. It answers the
/// daemon's commands as the relay and the phone would, and leaves what it saw in `dir`:
/// `commands` (every command, one per line), `paired` (the pair-result), `hello` (each
/// opened hello) and `replies` (each opened reply-result). Writing `answer` ("approve once",
/// "deny") makes the phone answer the next pending item.
final class FakeCloud {
    private let dir: URL
    private let emit: (RelayEvent) -> Void
    private let device: P256.Signing.PrivateKey
    private let lock = NSLock()
    private var code: Data?
    private var macID = ""
    private var macAgreement = Data()
    private var agreement = Curve25519.KeyAgreement.PrivateKey()
    private var zone: String?
    private var key: PairingKey?
    private var asked = false
    private var answered: Set<String> = []
    private var pendingItems: [String: String] = [:]
    private var replies = 0

    init(dir: URL, emit: @escaping (RelayEvent) -> Void) {
        self.dir = dir
        self.emit = emit
        let keyFile = dir.appendingPathComponent("device-key")
        device = (try? Data(contentsOf: keyFile)).flatMap { try? P256.Signing.PrivateKey(rawRepresentation: $0) } ?? P256.Signing.PrivateKey()
        try? device.rawRepresentation.write(to: keyFile)
        if let secret = try? Data(contentsOf: dir.appendingPathComponent("secret")),
           let zone = try? String(contentsOf: dir.appendingPathComponent("zone"), encoding: .utf8) {
            (key, self.zone) = (PairingKey(secret: secret), zone)
        }
        Thread.detachNewThread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 0.3)
                lock.withLock { answerIfAsked() }
            }
        }
    }

    func start() { emit(.ready(version: "fake")) }

    func handle(_ command: RelayCommand) {
        append("commands", String(decoding: RelayLine.encode(command), as: UTF8.self))
        lock.withLock {
            switch command {
            case .account:
                emit(.account(user: "_fakeuser", error: nil))
            case .watchRendezvous(let name, _):
                Thread.detachNewThread { [self] in rendezvous(name) }
            case .put(let zone, let name, let type, let fields):
                put(zone: zone, name: name, type: type, fields: fields)
            case .delete(_, let name):
                pendingItems[name] = nil
            case .respond(_, let name, let response):
                respond(name: name, response: response)
            default:
                break
            }
        }
    }

    private func rendezvous(_ name: String) {
        for _ in 0..<100 {
            if let qr = try? String(contentsOf: dir.appendingPathComponent("qr"), encoding: .utf8),
               let (code, _, macID, macAgreement) = CloudFeed.Rendezvous.parseSealed(qr: qr),
               CloudFeed.Rendezvous.recordName(code: code) == name {
                let zone = CloudFeed.Rendezvous.zoneName(code: code)
                lock.withLock {
                    (self.code, self.macID, self.macAgreement, self.zone, self.key) = (code, macID, macAgreement, zone, nil)
                    asked = false
                }
                emit(.rendezvous(name: name, sealed: try? CloudFeed.Rendezvous.seal(.ownZone(zone), code: code)))
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        emit(.rendezvous(name: name, sealed: nil))
    }

    private func put(zone: String, name: String, type: String, fields: [String: String]) {
        guard zone == self.zone else { return }
        guard let key else {
            // The Mac joined: ask to be paired, once.
            guard name == CloudFeed.State.hello, !asked, code != nil else { return }
            asked = true
            agreement = Curve25519.KeyAgreement.PrivateKey()
            let statement = PairingHandshake.phoneStatement(phoneAgreementKey: agreement.publicKey.rawRepresentation,
                                                            macAgreementKey: macAgreement, macID: macID)
            var message = FeedReply.pair(publicKey: device.publicKey.rawRepresentation, name: "Fake Phone")
            message[PairingHandshake.agreementKeyField] = agreement.publicKey.rawRepresentation.base64EncodedString()
            message[PairingHandshake.agreementSignatureField] = (try? device.signature(for: statement).derRepresentation)?.base64EncodedString()
            emit(.inbox(zone: zone, name: "pair", message: Self.string(message)))
            return
        }
        switch type {
        case CloudFeed.State.type where name == CloudFeed.State.hello:
            let opened = fields[CloudFeed.State.message].flatMap {
                try? SealedField.open($0, with: key, recordType: type, field: CloudFeed.State.message, recordName: name, from: .mac)
            }
            append("hello", opened ?? "UNREADABLE")
        case CloudFeed.Item.type where fields[CloudFeed.Item.note] == nil:
            pendingItems[name] = fields[CloudFeed.Item.item]
        case CloudFeed.Item.type:
            pendingItems[name] = nil
        default:
            break
        }
    }

    private func answerIfAsked() {
        let file = dir.appendingPathComponent("answer")
        guard let key, let zone, let answer = try? String(contentsOf: file, encoding: .utf8),
              let (name, value) = pendingItems.first(where: { !answered.contains($0.key) }),
              let json = try? SealedField.open(value, with: key, recordType: CloudFeed.Item.type, field: CloudFeed.Item.item,
                                               recordName: name, from: .mac),
              let item = FeedItem.parse(json) else { return }
        try? FileManager.default.removeItem(at: file)
        answered.insert(name)
        let words = answer.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let message = try? FeedReply.message(item: item, action: words[0], picks: words.count > 1 ? ["duration": words[1]] : [:],
                                                   keyId: DeviceKey.keyId(rawPublicKey: device.publicKey.rawRepresentation),
                                                   sign: { try device.signature(for: $0).derRepresentation }) else { return }
        replies += 1
        let record = "reply-\(replies)"
        guard let sealed = try? SealedField.seal(Self.string(message), with: key, recordType: CloudFeed.Inbox.type,
                                                 field: CloudFeed.Inbox.message, recordName: record, from: .phone) else { return }
        emit(.inbox(zone: zone, name: record, message: sealed))
    }

    private func respond(name: String, response: String) {
        if name == "pair" {
            append("paired", response)
            guard let json = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
                  let sealed = (json[PairingHandshake.sealedSecretField] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let secret = try? PairingHandshake.openSecret(sealed, phoneKey: agreement, macAgreementKey: macAgreement,
                                                                phoneDeviceKey: device.publicKey.rawRepresentation, macID: macID)
            else { return append("paired", "NO KEY") }
            key = PairingKey(secret: secret)
            try? secret.write(to: dir.appendingPathComponent("secret"))
            try? zone?.write(to: dir.appendingPathComponent("zone"), atomically: true, encoding: .utf8)
            append("paired", "KEY OK")
        } else if let key {
            let opened = try? SealedField.open(response, with: key, recordType: CloudFeed.Inbox.type, field: CloudFeed.Inbox.response,
                                               recordName: name, from: .mac)
            append("replies", opened ?? "UNREADABLE")
        }
    }

    private func append(_ file: String, _ line: String) {
        let url = dir.appendingPathComponent(file)
        let text = line.hasSuffix("\n") ? line : line + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func string(_ json: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), as: UTF8.self)
    }
}
#endif
