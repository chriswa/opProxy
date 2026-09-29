import Darwin
import Foundation
import OpProxyCore

/// 1Password scopes CLI authorization to the Unix session (getsid), and agents start each
/// tool call in a new session. A holder is a child the daemon spawns as the leader of its
/// own session; every `op` it runs shares that session, so 1Password authorizes them once.
/// Refreshing means starting a new holder, authorizing it, and switching to it.
enum SessionHolder {
    /// `opProxy session-holder`: runs `HolderRequest`s from stdin, replies on stdout, and
    /// exits once stdin closes and in-flight runs finish.
    static func run(paths: Paths) -> Never {
        let runner = LocalOp(candidates: paths.realOpCandidates)
        let writeLock = NSLock()
        let group = DispatchGroup()
        let reader = LineReader(fd: STDIN_FILENO)
        while let line = reader.next() {
            guard let request = try? JSONDecoder().decode(HolderRequest.self, from: line) else { continue }
            group.enter()
            DispatchQueue.global().async {
                let reply = HolderReply(id: request.id,
                                        response: runner.run(request.argv, extraEnv: request.env, timeout: request.timeout))
                if let body = try? JSONEncoder().encode(reply) {
                    writeLock.lock()
                    _ = UnixSocket.writeAll(STDOUT_FILENO, body + Data("\n".utf8))
                    writeLock.unlock()
                }
                group.leave()
            }
        }
        group.wait()
        exit(0)
    }
}

/// The daemon's handle on one holder process.
final class OpSession {
    let pid: pid_t
    private let toHolder: Int32
    private let lock = NSLock()
    private var nextId = 0
    private var waiting: [Int: (ProxyResponse) -> Void] = [:]
    private var alive = true
    private var closed = false

    struct BinaryChanged: Error, CustomStringConvertible {
        let path: String
        var description: String {
            "\(path) no longer matches the running daemon; reinstall with install.sh to restart it"
        }
    }

    /// Spawns `executable session-holder` as the leader of a new Unix session. The holder is
    /// what 1Password authorizes, so it must be this exact build: a binary swapped in on disk
    /// would otherwise receive the next refresh's authorization.
    init(executable: String) throws {
        guard let mine = CodeSignature.cdhashOfSelf(), CodeSignature.cdhash(file: executable) == mine else {
            throw BinaryChanged(path: executable)
        }
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
        // CLOEXEC_DEFAULT: the holder gets only the fds above, not the daemon's sockets.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable), strdup("session-holder"), nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, argv, environ)
        Darwin.close(toChild[0])
        Darwin.close(fromChild[1])
        guard rc == 0 else {
            Darwin.close(toChild[1]); Darwin.close(fromChild[0])
            throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO)
        }
        self.pid = pid
        toHolder = toChild[1]
        _ = fcntl(toHolder, F_SETFD, FD_CLOEXEC)
        let fromHolder = fromChild[0]
        _ = fcntl(fromHolder, F_SETFD, FD_CLOEXEC)
        Thread.detachNewThread { [self] in readReplies(fromHolder) }
    }

    var isUsable: Bool { lock.withLock { alive && !closed } }

    func run(_ argv: [String], extraEnv: [String: String], timeout: TimeInterval = 300) -> ProxyResponse {
        let done = DispatchSemaphore(value: 0)
        var result = ProxyResponse.failure("the 1Password session helper exited")
        // Writes happen under the lock so close() can't close the fd mid-write.
        let sent: Bool = lock.withLock {
            guard alive, !closed else { return false }
            nextId += 1
            let request = HolderRequest(id: nextId, argv: argv, env: extraEnv, timeout: timeout)
            guard let body = try? JSONEncoder().encode(request) else { return false }
            waiting[nextId] = { result = $0; done.signal() }
            if UnixSocket.writeAll(toHolder, body + Data("\n".utf8)) { return true }
            waiting.removeValue(forKey: nextId)
            return false
        }
        guard sent else { return result }
        done.wait()
        return result
    }

    /// Lets in-flight runs finish, then the holder exits.
    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            Darwin.close(toHolder)
        }
    }

    private func readReplies(_ fd: Int32) {
        let reader = LineReader(fd: fd)
        while let line = reader.next() {
            guard let reply = try? JSONDecoder().decode(HolderReply.self, from: line) else { continue }
            let waiter = lock.withLock { waiting.removeValue(forKey: reply.id) }
            waiter?(reply.response)
        }
        Darwin.close(fd)
        let orphans: [(ProxyResponse) -> Void] = lock.withLock {
            alive = false
            defer { waiting.removeAll() }
            return Array(waiting.values)
        }
        orphans.forEach { $0(.failure("the 1Password session helper exited")) }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
}

/// Runs the real `op` as a child of the current process, after checking it is 1Password's
/// signed binary: a wrapper swapped in at /opt/homebrew/bin/op would otherwise run inside
/// the authorized session.
struct LocalOp {
    let candidates: [String]
    private let verifier: VerifiedFile?

    init(candidates: [String]) {
        self.candidates = candidates
        let requirement = TestKnobs.value("OPPROXY_OP_REQUIREMENT") ?? CodeSignature.onePasswordCLI
        verifier = requirement == "none" ? nil : VerifiedFile(requirement: requirement)
    }

    func run(_ argv: [String], extraEnv: [String: String], timeout: TimeInterval) -> ProxyResponse {
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) && (verifier?.check($0) ?? true) }) else {
            return .failure("no 1Password-signed op at \(candidates.joined(separator: " or ")); refusing to run it")
        }
        // A minimal environment: nothing inherited from launchd or the plist reaches op.
        let inherited = ProcessInfo.processInfo.environment
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"] { env[key] = inherited[key] }
        env.merge(ProxyRequest.forwardedEnvironment(extraEnv)) { $1 }
        return Self.spawn(path, argv: argv, env: env, timeout: timeout)
    }

    /// Runs `op` as a child in this process's Unix session, which is what carries 1Password's
    /// authorization. macOS charges `op`'s reads of 1Password's group container to opProxy
    /// (one "access data from other apps" prompt per daemon start). Disclaiming
    /// responsibility instead makes every `op` process ask separately, so don't.
    static func spawn(_ path: String, argv: [String], env: [String: String], timeout: TimeInterval) -> ProxyResponse {
        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { return .failure("could not create pipes") }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let cArgs: [UnsafeMutablePointer<CChar>?] = ([path] + argv).map { strdup($0) } + [nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (cArgs + cEnv).forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, cArgs, cEnv)
        close(outPipe[1])
        close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0])
            return .failure("could not run \(path): \(String(cString: strerror(rc)))")
        }
        // Drain both pipes concurrently so a full stderr pipe can't block stdout.
        var stdout = Data(), stderr = Data()
        let group = DispatchGroup()
        for (fd, isOut) in [(outPipe[0], true), (errPipe[0], false)] {
            group.enter()
            DispatchQueue.global().async {
                let data = UnixSocket.readToEnd(fd)
                close(fd)
                if isOut { stdout = data } else { stderr = data }
                group.leave()
            }
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            kill(pid, SIGTERM)
            group.wait()
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return ProxyResponse(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }
}
