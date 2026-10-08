#if OPPROXY_TESTING
import CryptoKit
import Foundation
import OpProxyCore

/// `opProxy test-feed-client <socket> approve|deny [option] [flags]`: plays the phone for the
/// integration tests. Makes a software P-256 key, pairs it (the daemon needs
/// OPPROXY_TEST_AUTO_PAIR), waits for the next item, signs a statement per APPROVAL_FEED.md,
/// replies, and prints each reply-result line.
///   --unpaired     skip pairing
///   --tamper-hash  claim a document hash the feed never sent
///   --stale        sign the statement as if two minutes ago
///   --twice        send the same reply again
///   --doc FILE     write the item's document there
enum FeedTestClient {
    static func run(_ args: [String]) -> Never {
        let positional = args.filter { !$0.hasPrefix("--") && !isFlagValue($0, in: args) }
        guard positional.count >= 2 else { fail("usage: opProxy test-feed-client <socket> approve|deny [option] [flags]") }
        let (socket, action, pick) = (positional[0], positional[1], positional.dropFirst(2).first)
        guard let fd = UnixSocket.connect(path: socket) else { fail("cannot connect to \(socket)") }
        var tv = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let reader = LineReader(fd: fd, limit: 16 << 20)
        func send(_ obj: [String: Any]) {
            let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
            guard UnixSocket.writeAll(fd, data + Data("\n".utf8)) else { fail("write failed") }
        }
        // Pending items as of the last message read, oldest first.
        var items: [[String: Any]] = []
        func next(where match: ([String: Any]) -> Bool) -> [String: Any] {
            while let line = reader.next() {
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                switch obj["type"] as? String {
                case "snapshot": items = obj["items"] as? [[String: Any]] ?? []
                case "upsert":
                    let item = obj["item"] as! [String: Any]
                    if let i = items.firstIndex(where: { $0["id"] as? String == item["id"] as? String }) { items[i] = item } else { items.append(item) }
                case "remove": items.removeAll { $0["id"] as? String == obj["id"] as? String }
                default: break
                }
                if match(obj) { return obj }
            }
            fail("feed closed or timed out")
        }

        let key = P256.Signing.PrivateKey()
        let keyId = DeviceKey.keyId(rawPublicKey: key.publicKey.rawRepresentation)
        if !args.contains("--unpaired") {
            send(["type": "pair", "publicKey": key.publicKey.rawRepresentation.base64EncodedString(), "name": "Test Phone"])
            let result = next { $0["type"] as? String == "pair-result" }
            guard result["ok"] as? Bool == true else { fail("pairing failed: \(result)") }
        }

        if items.isEmpty { _ = next { _ in !items.isEmpty } }
        let found = items[0]
        let document = found["document"] as! String
        if let i = args.firstIndex(of: "--doc"), i + 1 < args.count {
            try? document.write(toFile: args[i + 1], atomically: true, encoding: .utf8)
        }
        var hash = sha256Hex(Data(document.utf8))
        if args.contains("--tamper-hash") { hash = sha256Hex(Data((document + " ").utf8)) }
        var statement: [String: Any] = [
            "v": 1, "provider": "opProxy", "id": found["id"]!, "revision": found["revision"]!,
            "challenge": found["challenge"]!, "documentSha256": hash, "action": action, "picks": [String: String](),
            "keyId": keyId, "signedAt": Int64((Date().timeIntervalSince1970 - (args.contains("--stale") ? 120 : 0)) * 1000),
        ]
        if let pick { statement["picks"] = [RemoteCard.picker: pick] }
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: statement, options: [.sortedKeys]), as: UTF8.self)
        let signature = try! key.signature(for: Data(text.utf8)).derRepresentation
        let reply: [String: Any] = ["type": "reply", "id": found["id"]!, "keyId": keyId, "statement": text,
                                    "signature": signature.base64EncodedString()]
        for _ in 0..<(args.contains("--twice") ? 2 : 1) {
            send(reply)
            let result = next { $0["type"] as? String == "reply-result" }
            print(String(decoding: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        }
        exit(0)
    }

    private static func isFlagValue(_ arg: String, in args: [String]) -> Bool {
        guard let i = args.firstIndex(of: arg), i > 0 else { return false }
        return args[i - 1] == "--doc"
    }
}
#endif
