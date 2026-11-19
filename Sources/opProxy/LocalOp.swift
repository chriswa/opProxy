import Darwin
import Foundation
import OpProxyCore

/// Runs the real `op` as a child of the current process, after checking it is 1Password's
/// signed binary. The daemon only asks it which accounts this Mac has (`account list`, which
/// never prompts), but a wrapper swapped in at /opt/homebrew/bin/op could otherwise choose
/// which account opProxy authorizes.
struct LocalOp {
    let candidates: [String]
    private let verifier: VerifiedFile?

    init(candidates: [String]) {
        self.candidates = candidates
        let requirement = TestKnobs.value("OPPROXY_OP_REQUIREMENT") ?? CodeSignature.onePasswordCLI
        verifier = requirement == "none" ? nil : VerifiedFile(requirement: requirement)
    }

    func run(_ argv: [String], extraEnv: [String: String], timeout: TimeInterval) -> ProxyResponse {
        var path: String?
        var expected: Data?
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            if let verifier {
                guard let hash = verifier.check(candidate) else { continue }
                // Spawn the resolved file itself: the symlink is just one more thing to swap.
                (path, expected) = (URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path, hash)
            } else {
                path = candidate
            }
            break
        }
        guard var path else {
            return .failure("no 1Password-signed op at \(candidates.joined(separator: " or ")); refusing to run it")
        }
        #if OPPROXY_TESTING
        // Simulates losing the race: a different binary is at the path by the time it's exec'd.
        if let swapped = TestKnobs.value("OPPROXY_TEST_SWAP_OP") { path = swapped }
        #endif
        // A minimal environment: nothing inherited from launchd or the plist reaches op.
        let inherited = ProcessInfo.processInfo.environment
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"] { env[key] = inherited[key] }
        env.merge(ProxyRequest.forwardedEnvironment(extraEnv)) { $1 }
        return Self.spawn(path, argv: argv, env: env, timeout: timeout, expectedCDHash: expected)
    }

    /// Runs `op` as a child of this process. macOS charges `op`'s reads of 1Password's group
    /// container to opProxy (one "access data from other apps" prompt per daemon start).
    /// Disclaiming responsibility instead makes every `op` process ask separately, so don't.
    ///
    /// With `expectedCDHash`, `op` starts suspended and only runs if the kernel loaded exactly
    /// the binary whose signature was checked. Checking the file and then exec'ing its path
    /// leaves a window where a same-user attacker can swap it.
    static func spawn(_ path: String, argv: [String], env: [String: String], timeout: TimeInterval,
                      expectedCDHash: Data?) -> ProxyResponse {
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
        let suspended = expectedCDHash != nil ? Int16(POSIX_SPAWN_START_SUSPENDED) : 0
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT) | suspended)

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
        if let expectedCDHash {
            guard CodeSignature.cdhash(pid: pid) == expectedCDHash else {
                kill(pid, SIGKILL)
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
                close(outPipe[0]); close(errPipe[0])
                return .failure("\(path) changed between its 1Password signature check and launch; refusing to run it")
            }
            kill(pid, SIGCONT)
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
