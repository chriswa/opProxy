import Darwin
import Foundation
import OpProxyCore

/// Runs when invoked as `op`. Anything opProxy doesn't handle execs the real `op`, so the
/// worst case is 1Password's usual behaviour.
enum Shim {
    static func run(_ args: [String]) -> Never {
        let env = ProcessInfo.processInfo.environment
        let paths = Paths(environment: env)

        // Every read goes to the daemon, from agents and terminals alike, so its dialog is
        // always the one that appears. It decides from the process tree who is asking.
        guard !paths.isDisabled, !ProxyRequest.bypassesDesktopApp(env),
              case .proxy = OpCommand(argv: args).routing,
              let fd = UnixSocket.connect(path: paths.socket.path)
        else { passthrough(paths.realOp, args) }
        let plan = OpCommand(argv: args).routing

        let surface = [env["SPACETERM_SURFACE_ID"], env["SPACETERM_NODE_ID"]].compactMap { $0 }.first { !$0.isEmpty }
        let request = ProxyRequest(
            session: AgentSession.detect(environment: env, ancestry: { ProcessTree.ancestry(of: getpid()) }),
            surfaceId: surface, argv: args, env: ProxyRequest.forwardedEnvironment(env),
            cwd: FileManager.default.currentDirectoryPath)

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
        FileHandle.standardError.write(response.stderr)
        if response.exitCode == 0, case .proxy(let plan) = plan, let outFile = plan.outFile {
            writeOutFile(outFile, contents: response.stdout)
        }
        FileHandle.standardOutput.write(response.stdout)
        exit(response.exitCode)
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
        FileHandle.standardError.write(Data("[ERROR] opProxy: \(message)\n".utf8))
        exit(1)
    }
}
