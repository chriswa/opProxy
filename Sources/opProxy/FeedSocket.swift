import Darwin
import Foundation
import OpProxyCore

/// The approval feed on a Unix socket (`Paths.approvalFeed`), which Spaceterm relays to its
/// phone app: newline-delimited JSON, the full state on every connection (APPROVAL_FEED.md).
/// Client state lives on the feed's queue.
final class FeedSocket: FeedTransport {
    private let path: URL
    private let log: Log
    private weak var feed: ApprovalFeed?
    private var clients: [Int: Int32] = [:]
    private var nextClient = 0

    init(path: URL, log: Log) {
        self.path = path
        self.log = log
    }

    func attach(_ feed: ApprovalFeed) throws {
        self.feed = feed
        let listener = try UnixSocket.listen(path: path.path)
        log.write("approval feed on \(path.path)")
        Thread.detachNewThread { [self] in
            while true {
                let fd = accept(listener, nil, nil)
                if fd < 0 { continue }
                UnixSocket.noSigpipe(fd)
                // A client that stops reading mustn't stall everyone else's updates.
                var tv = timeval(tv_sec: 2, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                serve(fd, feed: feed)
            }
        }
    }

    func send(_ message: FeedMessage) {
        for client in clients.keys { send(client, message.json) }
    }

    private func serve(_ fd: Int32, feed: ApprovalFeed) {
        feed.queue.async { [self] in
            let client = nextClient
            nextClient += 1
            let state = feed.state()
            clients[client] = fd
            send(client, FeedMessage.hello(pairedKeys: state.pairedKeys, mac: state.mac).json)
            if let status = state.status { send(client, FeedMessage.status(status).json) }
            send(client, ["type": "snapshot", "items": state.items.map(\.item)])
            Thread.detachNewThread { [self] in
                let reader = LineReader(fd: fd, limit: 1 << 20)
                while let line = reader.next() {
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    feed.receive(message) { [self] response in send(client, response) }
                }
                feed.queue.async { [self] in
                    clients.removeValue(forKey: client)
                    close(fd)
                }
            }
        }
    }

    /// A failed write drops the client; its reader then sees EOF and cleans up.
    private func send(_ client: Int, _ message: [String: Any]) {
        guard let fd = clients[client],
              let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return }
        if !UnixSocket.writeAll(fd, data + Data("\n".utf8)) { shutdown(fd, SHUT_RDWR) }
    }
}
