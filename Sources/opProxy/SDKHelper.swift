import Darwin
import Foundation
import OpProxyCore
import Security

/// Where the daemon's 1Password helper comes from, and what it must be signed as.
struct HelperSpec {
    let executable: String
    let arguments: [String]
    /// A code requirement the file must meet; nil when this build has no team to require.
    let requirement: String?

    /// The 1Password app's SDK library, which the helper loads, in the order the SDK looks.
    static let onePasswordLibraries = [
        "/Applications/1Password.app/Contents/Frameworks/libop_sdk_ipc_client.dylib",
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/1Password.app/Contents/Frameworks/libop_sdk_ipc_client.dylib").path,
    ]
    static let onePasswordLibraryRequirement = #"anchor apple generic and certificate leaf[subject.OU] = "2BUA8C4S2C""#
    static let identifier = "com.chriswa.opproxy.sdk-helper"

    /// `Contents/Helpers/opproxy-sdk` beside this executable, signed by this build's team.
    static func bundled(beside executable: String) -> HelperSpec {
        let contents = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent()
        let path = contents.appendingPathComponent("Helpers/opproxy-sdk").path
        let requirement = CodeSignature.teamOfSelf().map {
            #"anchor apple generic and identifier "\#(identifier)" and certificate leaf[subject.OU] = "\#($0)""#
        }
        return HelperSpec(executable: path, arguments: [], requirement: requirement)
    }

    /// Checks the helper, and the 1Password library it will load, before it is started; the
    /// helper's code hash is then compared with what the kernel loads.
    func verify() throws -> Data? {
        if arguments.first == "fake-sdk-helper" {
            // Tests: the stand-in is this very build.
            guard let mine = CodeSignature.cdhashOfSelf(), CodeSignature.cdhash(file: executable) == mine else {
                throw HelperError("\(executable) isn't this build; reinstall with install.sh to restart it")
            }
        } else {
            guard let library = Self.onePasswordLibraries.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                throw HelperError("the 1Password app isn't installed in Applications")
            }
            guard CodeSignature.file(library, satisfies: Self.onePasswordLibraryRequirement) else {
                throw HelperError("\(library) isn't signed by 1Password; refusing to load it")
            }
        }
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw HelperError("\(executable) is missing") }
        if let requirement, !CodeSignature.file(executable, satisfies: requirement) {
            throw HelperError("\(executable) isn't signed by this build's team; reinstall opProxy")
        }
        return CodeSignature.cdhash(file: executable)
    }
}

struct HelperError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The daemon's handle on one helper process: one 1Password authorization. Its only channel
/// is the pipe pair to the daemon, so nothing else can make requests of it.
final class SDKSession: OnePassword {
    let pid: pid_t
    private let toHelper: Int32
    private let lock = NSLock()
    /// Held while writing a request, apart from `lock`: a write can block until the helper
    /// reads, and replies must keep flowing meanwhile.
    private let writing = NSLock()
    private var nextId = 0
    private var waiting: [Int: (Result<JSONValue, SDK.Failure>) -> Void] = [:]
    private var alive = true
    private var closed = false

    init(_ spec: HelperSpec) throws {
        let expected = try spec.verify()
        var toChild: [Int32] = [0, 0], fromChild: [Int32] = [0, 0]
        guard pipe(&toChild) == 0, pipe(&fromChild) == 0 else { throw POSIXError(.EMFILE) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, toChild[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], STDOUT_FILENO)
        posix_spawn_file_actions_addinherit_np(&actions, STDERR_FILENO)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // CLOEXEC_DEFAULT: the helper gets only the fds above, not the daemon's sockets.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_START_SUSPENDED))
        // A minimal environment: nothing inherited from launchd or the plist reaches it.
        let inherited = ProcessInfo.processInfo.environment
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"] { env[key] = inherited[key] }
        #if OPPROXY_TESTING
        for (key, value) in inherited where key.hasPrefix("OPPROXY_") { env[key] = value }
        #endif
        let cArgs: [UnsafeMutablePointer<CChar>?] = ([spec.executable] + spec.arguments).map { strdup($0) } + [nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (cArgs + cEnv).forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, spec.executable, &actions, &attr, cArgs, cEnv)
        Darwin.close(toChild[0])
        Darwin.close(fromChild[1])
        guard rc == 0 else {
            Darwin.close(toChild[1]); Darwin.close(fromChild[0])
            throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO)
        }
        // Only the exact binary that was checked may run: the file could have been swapped
        // between the check and the spawn.
        guard CodeSignature.cdhash(pid: pid) == expected, expected != nil else {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            Darwin.close(toChild[1]); Darwin.close(fromChild[0])
            throw HelperError("\(spec.executable) changed between its signature check and launch; refusing to run it")
        }
        kill(pid, SIGCONT)
        self.pid = pid
        toHelper = toChild[1]
        _ = fcntl(toHelper, F_SETFD, FD_CLOEXEC)
        let fromHelper = fromChild[0]
        _ = fcntl(fromHelper, F_SETFD, FD_CLOEXEC)
        Thread.detachNewThread { [self] in readReplies(fromHelper) }
    }

    var isUsable: Bool { lock.withLock { alive && !closed } }

    /// One request. Authorizing waits for you at 1Password's prompt, so it gets longer.
    func call(_ method: String, _ params: [String: JSONValue] = [:], timeout: TimeInterval = 90) -> Result<JSONValue, SDK.Failure> {
        let done = DispatchSemaphore(value: 0)
        var result: Result<JSONValue, SDK.Failure> = .failure(SDK.Failure(.unauthorized, "opProxy's 1Password helper exited"))
        let id: Int? = lock.withLock {
            guard alive, !closed else { return nil }
            nextId += 1
            waiting[nextId] = { result = $0; done.signal() }
            return nextId
        }
        guard let id else { return result }
        let request = JSONValue.object(["id": .number(Double(id)), "method": .string(method), "params": .object(params)])
        // close() takes `writing` too, so the fd can't be closed mid-write.
        let sent = writing.withLock {
            guard !lock.withLock({ closed }), let body = try? JSONEncoder().encode(request) else { return false }
            return UnixSocket.writeAll(toHelper, body + Data("\n".utf8))
        }
        guard sent else {
            lock.withLock { _ = waiting.removeValue(forKey: id) }
            return .failure(SDK.Failure(.unauthorized, "opProxy's 1Password helper exited"))
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            lock.withLock { _ = waiting.removeValue(forKey: id) }
            return .failure(SDK.Failure(.failed, "1Password didn't answer within \(Int(timeout)) seconds"))
        }
        return result
    }

    /// Lets in-flight requests finish, then the helper exits.
    func close() {
        writing.withLock {
            let first = lock.withLock { () -> Bool in
                defer { closed = true }
                return !closed
            }
            if first { Darwin.close(toHelper) }
        }
    }

    private struct Reply: Decodable {
        struct Failure: Decodable {
            let kind: SDK.Failure.Kind
            let message: String
        }
        let id: Int
        let result: JSONValue?
        let error: Failure?
    }

    private func readReplies(_ fd: Int32) {
        // Documents come back whole, base64 in one line.
        let reader = LineReader(fd: fd, limit: 1 << 30)
        while let line = reader.next() {
            guard let reply = try? JSONDecoder().decode(Reply.self, from: line) else { continue }
            let waiter = lock.withLock { waiting.removeValue(forKey: reply.id) }
            if let error = reply.error {
                waiter?(.failure(SDK.Failure(error.kind, error.message)))
            } else {
                waiter?(.success(reply.result ?? .null))
            }
        }
        Darwin.close(fd)
        let orphans: [(Result<JSONValue, SDK.Failure>) -> Void] = lock.withLock {
            alive = false
            defer { waiting.removeAll() }
            return Array(waiting.values)
        }
        orphans.forEach { $0(.failure(SDK.Failure(.unauthorized, "opProxy's 1Password helper exited"))) }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    // MARK: OnePassword

    private func decode<T: Decodable>(_ result: Result<JSONValue, SDK.Failure>, as: T.Type = T.self) -> Result<T, SDK.Failure> {
        result.flatMap { value in
            do { return .success(try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))) } catch {
                return .failure(SDK.Failure(.failed, "opProxy couldn't read 1Password's answer: \(error)"))
            }
        }
    }

    private static func json<T: Encodable>(_ value: T) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))) ?? .null
    }

    private static func ids(_ vaultId: String, _ itemId: String) -> [String: JSONValue] {
        ["vaultId": .string(vaultId), "itemId": .string(itemId)]
    }

    func authorize(account: String, version: String) -> Result<Void, SDK.Failure> {
        call("authorize", ["account": .string(account), "version": .string(version)], timeout: 180).map { _ in () }
    }

    func vaults() -> Result<[SDK.VaultOverview], SDK.Failure> { decode(call("vaults")) }

    func vault(_ vaultId: String) -> Result<SDK.VaultOverview, SDK.Failure> {
        decode(call("vault", ["vaultId": .string(vaultId)]))
    }

    func items(vaultId: String, archived: Bool) -> Result<[SDK.ItemOverview], SDK.Failure> {
        decode(call("items", ["vaultId": .string(vaultId), "archived": .bool(archived)]))
    }

    func item(vaultId: String, itemId: String) -> Result<SDK.Item, SDK.Failure> {
        decode(call("item", Self.ids(vaultId, itemId)))
    }

    func resolve(_ reference: String) -> Result<String, SDK.Failure> {
        decode(call("resolve", ["reference": .string(reference)]))
    }

    func file(vaultId: String, itemId: String, attributes: JSONValue) -> Result<Data, SDK.Failure> {
        var params = Self.ids(vaultId, itemId)
        params["attributes"] = attributes
        // Go encodes bytes as base64.
        return decode(call("file", params), as: String.self).flatMap {
            Data(base64Encoded: $0).map { .success($0) } ?? .failure(SDK.Failure(.failed, "the document wasn't base64"))
        }
    }

    func create(_ params: SDK.ItemCreate) -> Result<SDK.Item, SDK.Failure> {
        decode(call("create", ["create": Self.json(params)]))
    }

    func put(_ item: SDK.Item) -> Result<SDK.Item, SDK.Failure> {
        decode(call("put", ["item": Self.json(item)]))
    }

    func delete(vaultId: String, itemId: String) -> Result<Void, SDK.Failure> {
        call("delete", Self.ids(vaultId, itemId)).map { _ in () }
    }

    func archive(vaultId: String, itemId: String) -> Result<Void, SDK.Failure> {
        call("archive", Self.ids(vaultId, itemId)).map { _ in () }
    }
}

extension CodeSignature {
    /// The Team ID this process is signed with, or nil for ad-hoc and unsigned builds.
    static func teamOfSelf() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
