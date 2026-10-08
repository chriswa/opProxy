import AppKit
import Foundation
import OpProxyCore

/// The daemon runs as a LaunchAgent (restarted by launchd if it crashes), which opening the app
/// or install.sh writes. These map the menu's Open at Login / Restart / Quit onto it.
enum LaunchAgent {
    static let label = "com.chriswa.opproxy"
    private static var domain: String { "gui/\(getuid())" }

    /// Whether launchd will start the daemon at login (`launchctl enable`/`disable`).
    static var opensAtLogin: Bool {
        let out = launchctl(["print-disabled", domain]).output
        return !out.split(separator: "\n").contains { line in
            line.contains("\"\(label)\"") && (line.contains("=> disabled") || line.contains("=> true"))
        }
    }

    static func setOpensAtLogin(_ on: Bool) {
        _ = launchctl([on ? "enable" : "disable", "\(domain)/\(label)"])
    }

    /// Kills this instance and starts a fresh one. launchctl runs detached, so it outlives us.
    static func restart() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "-k", "\(domain)/\(label)"]
        try? task.run()
    }

    /// A clean exit: the agent only relaunches after a crash, so this stays quit until login
    /// or until the app is opened.
    static func quit() { NSApp.terminate(nil) }

    private static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// The program the installed agent runs, if there is one.
    static var installedProgram: String? {
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return (dict["ProgramArguments"] as? [String])?.first
    }

    /// Writes the agent for `executable` and (re)starts it, keeping the user's Open at Login
    /// choice; returns once the daemon is listening (or after 5 seconds).
    static func install(executable: String, paths: Paths) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        try paths.ensureStateDir()
        let agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "daemon"],
            "RunAtLoad": true,
            // Relaunch after a crash, but not after the menu's Quit (a clean exit).
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "StandardErrorPath": "\(home)/.opProxy/launchd.log",
            "StandardOutPath": "\(home)/.opProxy/launchd.log",
        ]
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0).write(to: plist, options: .atomic)
        launchctl(["bootout", "\(domain)/\(label)"])
        // bootout returns before the job is fully gone; bootstrapping too early fails with EIO.
        for _ in 0..<50 where launchctl(["print", "\(domain)/\(label)"]).status == 0 { usleep(100_000) }
        try? FileManager.default.removeItem(at: paths.socket)
        // A disabled agent (Open at Login unchecked) can't be bootstrapped: enable it to start
        // it now, then put the choice back, since disabling only affects future logins.
        let wasDisabled = !opensAtLogin
        setOpensAtLogin(true)
        launchctl(["bootstrap", domain, plist.path])
        if wasDisabled { setOpensAtLogin(false) }
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: paths.socket.path) { usleep(100_000) }
    }

    /// Opening opProxy.app (Finder, `open`): installs the agent if this Mac has none (or its
    /// program is gone), starts the daemon if it isn't running, and has it show Setup.
    static func startFromAppLaunch(paths: Paths, executable: String) -> Never {
        Setup.linkCommands(to: executable, paths: paths)
        if installedProgram.map({ !FileManager.default.fileExists(atPath: $0) }) ?? true {
            do { try install(executable: executable, paths: paths) } catch { fail("could not install the background agent: \(error)") }
        } else if UnixSocket.connect(path: paths.socket.path).map({ close($0) }) == nil {
            if launchctl(["kickstart", "\(domain)/\(label)"]).status != 0 { launchctl(["bootstrap", domain, plist.path]) }
            for _ in 0..<50 where !FileManager.default.fileExists(atPath: paths.socket.path) { usleep(100_000) }
        }
        _ = daemonStatus(.showSetup)
        exit(0)
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let task = Process()
        let out = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
