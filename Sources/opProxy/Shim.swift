import Darwin
import Foundation
import OpProxyCore

/// Runs when invoked as `op`. Anything opProxy doesn't handle execs the real `op`, so the
/// worst case is 1Password's usual behaviour.
enum Shim {
    static func run(_ args: [String]) -> Never {
        let env = ProcessInfo.processInfo.environment
        let paths = Paths(environment: env)

        if paths.isDisabled { passthrough(paths.realOp, args) }
        let plan = OpCommand(argv: args).routing
        let request = ProxyRequest(
            session: AgentSession.detect(environment: env, ancestry: { ProcessTree.ancestry(of: getpid()) }),
            labelEnvironment: OpProxyConfig.load(paths)?.labelEnvironment(env), argv: args, env: ProxyRequest.forwardedEnvironment(env),
            cwd: FileManager.default.currentDirectoryPath)

        // Every read and item write goes to the daemon, from agents and terminals alike, so its
        // dialog is always the one that appears. It decides from the process tree who is asking.
        // Anything else still tells the daemon before it goes to the real op.
        if ProxyRequest.bypassesDesktopApp(env) {
            notePassthrough(paths, request, reason: "uses a service account, Connect or OP_SESSION_ credential")
            passthrough(paths.realOp, args)
        }
        if case .passthrough(let reason) = plan {
            notePassthrough(paths, request, reason: reason)
            passthrough(paths.realOp, args)
        }
        guard let fd = UnixSocket.connect(path: paths.socket.path) else { passthrough(paths.realOp, args) }

        guard let body = try? JSONEncoder().encode(DaemonMessage.proxy(request)),
              UnixSocket.writeAll(fd, body + Data("\n".utf8)) else {
            close(fd)
            passthrough(paths.realOp, args)
        }
        let reply = UnixSocket.readToEnd(fd)
        close(fd)
        guard let response = try? JSONDecoder().decode(ProxyResponse.self, from: reply) else {
            fail("the opProxy daemon closed the connection without a reply; see \(paths.log.path)")
        }
        if response.passthrough == true { passthrough(paths.realOp, args) }
        // write(2), not FileHandle: a reader that closed early (`| head`) is EPIPE, not a crash.
        _ = UnixSocket.writeAll(STDERR_FILENO, response.stderr)
        if response.exitCode == 0, case .proxy(let plan) = plan, let outFile = plan.outFile {
            writeOutFile(outFile, contents: response.stdout)
        }
        _ = UnixSocket.writeAll(STDOUT_FILENO, response.stdout)
        exit(response.exitCode)
    }

    /// Tells the daemon about a call opProxy won't answer, and waits briefly for it to note who
    /// is asking (which needs this process alive). Without a daemon, nothing is recorded.
    static func notePassthrough(_ paths: Paths, _ request: ProxyRequest, reason: String) {
        guard let fd = UnixSocket.connect(path: paths.socket.path) else { return }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let body = try? JSONEncoder().encode(DaemonMessage.passedThrough(PassthroughNotice(request: request, reason: reason))),
              UnixSocket.writeAll(fd, body + Data("\n".utf8)) else { return }
        var ack: UInt8 = 0
        _ = read(fd, &ack, 1)
    }

    static func passthrough(_ realOp: String, _ args: [String]) -> Never {
        let argv = (["op"] + args).map { strdup($0) } + [nil]
        execv(realOp, argv)
        fail("could not exec \(realOp): \(String(cString: strerror(errno)))")
    }

    /// Matches `op read --out-file`: writes the secret, then prints the file's absolute path.
    static func writeOutFile(_ out: OutFile, contents: Data) -> Never {
        let url = URL(fileURLWithPath: out.path).standardizedFileURL
        if FileManager.default.fileExists(atPath: url.path), !out.force {
            fail("\(url.path) already exists; pass --force to overwrite it")
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(out.mode))
        guard fd >= 0 else { fail("could not write \(url.path): \(String(cString: strerror(errno)))") }
        fchmod(fd, mode_t(out.mode))
        let ok = UnixSocket.writeAll(fd, contents)
        close(fd)
        guard ok else { fail("could not write \(url.path)") }
        print(url.path)
        exit(0)
    }

    static func fail(_ message: String) -> Never {
        _ = UnixSocket.writeAll(STDERR_FILENO, Data("[ERROR] opProxy: \(message)\n".utf8))
        exit(1)
    }
}
