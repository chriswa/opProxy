import AppKit
import Foundation
import OpProxyCore

/// The daemon runs as the LaunchAgent install.sh writes (restarted by launchd if it crashes).
/// These map the menu's Open at Login / Restart / Quit onto it.
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

    /// Opening opProxy.app (Finder, `open`) starts the daemon if it isn't running.
    static func startFromAppLaunch(paths: Paths) -> Never {
        if let fd = UnixSocket.connect(path: paths.socket.path) { close(fd); exit(0) }
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist").path
        if launchctl(["kickstart", "\(domain)/\(label)"]).status != 0 {
            _ = launchctl(["bootstrap", domain, plist])
        }
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
