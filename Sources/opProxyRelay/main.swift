import Foundation
import FeedProtocol
import Security

// opProxy iCloud Relay: the only part of opProxy signed for CloudKit. The daemon starts it as
// a child while it has an iPhone to talk to, and speaks `RelayCommand`/`RelayEvent` lines on
// its stdin and stdout (FeedProtocol/Relay.swift). It exits when the daemon closes stdin.

let arguments = CommandLine.arguments

/// Whether this binary may use the container: CloudKit raises an exception rather than
/// failing when it can't, and only a build signed with the provisioning profile can.
func signedForCloudKit() -> Bool {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
    return (containers as? [String] ?? []).contains(CloudFeed.container)
}

#if OPPROXY_TESTING
if arguments.dropFirst().first == "test-phone" {
    guard signedForCloudKit() else { print("not signed for CloudKit"); exit(2) }
    TestPhone.run(Array(arguments.dropFirst(2)))
}
#endif

if arguments.count > 1 {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    print("opProxy iCloud Relay \(version): started by the opProxy daemon, not by hand.")
    exit(arguments[1] == "--version" ? 0 : 2)
}

let output = NSLock()
func emit(_ event: RelayEvent) {
    let line = RelayLine.encode(event)
    output.withLock { FileHandle.standardOutput.write(line) }
}

signal(SIGPIPE, SIG_IGN)
var handle: (RelayCommand) -> Void
#if OPPROXY_TESTING
let fakeCloud = ProcessInfo.processInfo.environment["OPPROXY_TEST_FAKE_CLOUD"].map {
    FakeCloud(dir: URL(fileURLWithPath: $0), emit: emit)
}
#else
let fakeCloud: Relay? = nil
#endif
if let fakeCloud {
    fakeCloud.start()
    handle = fakeCloud.handle
} else {
    guard signedForCloudKit() else {
        emit(.log(message: "this relay isn't signed for CloudKit (\(CloudFeed.container)), so it can't reach the iPhone"))
        exit(2)
    }
    let relay = Relay(emit: emit)
    relay.start()
    handle = relay.handle
}

var buffer = Data()
while true {
    let chunk = FileHandle.standardInput.availableData
    if chunk.isEmpty { exit(0) }
    buffer += chunk
    while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
        let line = buffer[buffer.startIndex..<newline]
        buffer = Data(buffer[buffer.index(after: newline)...])
        if let command = RelayLine.decode(RelayCommand.self, Data(line)) {
            handle(command)
        } else if !line.isEmpty {
            emit(.log(message: "relay: unreadable command"))
        }
    }
}
