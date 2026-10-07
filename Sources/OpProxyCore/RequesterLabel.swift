import Foundation

/// How the app an agent or terminal runs in names it: "Kevin" in “fix flaky tests”. Display
/// only: it comes from a command the user configured, fed by the caller's environment.
public struct RequesterLabel: Equatable {
    /// The agent's name. Apps may reuse a name for another agent later, so it is shown live
    /// and never stored.
    public let name: String?
    /// What the agent is working on; stored with lasting approvals to tell them apart.
    public let title: String?
    /// Opens the agent or tab in its app, from the dialog.
    public let openURL: URL?
    /// The app's stable ID for it, passed to phones as the document's `surfaceId`.
    public let id: String?

    public init(name: String? = nil, title: String? = nil, openURL: URL? = nil, id: String? = nil) {
        self.name = name
        self.title = title
        self.openURL = openURL
        self.id = id
    }

    /// The command's JSON answer; nil when it says nothing usable.
    public static func parse(_ data: Data) -> RequesterLabel? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func text(_ key: String, limit: Int = 200) -> String? {
            nonEmpty((json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).map { String($0.prefix(limit)) }
        }
        let label = RequesterLabel(name: text("name", limit: 60), title: text("title"), openURL: text("openURL").flatMap(URL.init),
                                   id: text("id"))
        return label == RequesterLabel() ? nil : label
    }
}

/// `~/.opProxy/config.json`. Optional, and re-read for every request.
public struct OpProxyConfig: Decodable {
    /// Names requesters by running a command (README, "Naming agents").
    public struct Labeler: Decodable {
        /// The program and its arguments. It gets a JSON request on stdin and prints a label.
        public let command: [String]
        /// Variables the `op` shim copies from the caller's environment for the command.
        public let environment: [String]?
        public let timeoutSeconds: Double?
    }

    public let requesterLabel: Labeler?

    public static func load(_ paths: Paths) -> OpProxyConfig? {
        guard let data = try? Data(contentsOf: paths.config) else { return nil }
        return try? JSONDecoder().decode(OpProxyConfig.self, from: data)
    }

    /// The variables of `env` the label command asked for.
    public func labelEnvironment(_ env: [String: String]) -> [String: String] {
        let names = Set(requesterLabel?.environment ?? [])
        return env.filter { names.contains($0.key) }
    }
}

extension OpProxyConfig.Labeler {
    /// Runs the command with `input` on stdin; nil if it fails, says nothing, or overruns
    /// its timeout (1 second unless configured), since every request waits for it.
    public func label(_ input: [String: Any]) -> RequesterLabel? {
        guard let program = command.first, let body = try? JSONSerialization.data(withJSONObject: input) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = Array(command.dropFirst())
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return nil }
        stdin.fileHandleForWriting.write(body)
        try? stdin.fileHandleForWriting.close()
        // Read concurrently so a chatty command can't fill the pipe and stall.
        var output = Data()
        let reader = DispatchQueue(label: "opProxy.labeler")
        let read = DispatchSemaphore(value: 0)
        reader.async {
            output = stdout.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        guard finished.wait(timeout: .now() + min(max(timeoutSeconds ?? 1, 0.1), 5)) == .success else {
            process.terminate()
            return nil
        }
        _ = read.wait(timeout: .now() + 0.5)
        return process.terminationStatus == 0 ? RequesterLabel.parse(output) : nil
    }
}
