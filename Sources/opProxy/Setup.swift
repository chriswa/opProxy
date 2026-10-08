import AppKit
import OpProxyCore
import SwiftUI

/// What opProxy needs beyond its own background agent, checked live: the 1Password CLI, a
/// shell that finds opProxy's `op` first, and optionally a paired iPhone. Opening the app shows
/// it, as does the menu's Setup….
enum Setup {
    /// Where opening the app puts `op` and `opProxy`, for shells to find: `~/.opProxy/bin`.
    static func binDir(_ paths: Paths) -> URL { paths.stateDir.appendingPathComponent("bin") }

    /// Points `op` and `opProxy` in `binDir` at `executable`.
    static func linkCommands(to executable: String, paths: Paths) {
        let fm = FileManager.default
        let binDir = binDir(paths)
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        for name in ["op", "opProxy"] {
            let link = binDir.appendingPathComponent(name)
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == executable { continue }
            try? fm.removeItem(at: link)
            try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: executable)
        }
    }

    /// The 1Password CLI opProxy runs, if installed.
    static func realOp(_ paths: Paths) -> String? {
        paths.realOpCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The `op` a new login shell runs, resolved through symlinks.
    static func shellOp() -> String? {
        let task = Process()
        let out = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lic", "command -v op"]
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// The line that puts `binDir` first on PATH.
    static func pathLine(_ paths: Paths) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = binDir(paths).path
        return #"export PATH=""# + (dir.hasPrefix(home + "/") ? "$HOME" + dir.dropFirst(home.count) : dir) + #":$PATH""#
    }

    /// Links `op` and `opProxy` to `executable` and puts them first on PATH for new shells. The
    /// line goes at the end of both files, so it comes after anything else that prepends
    /// (Homebrew's shellenv, for one).
    static func addToShell(executable: String, paths: Paths) throws {
        linkCommands(to: executable, paths: paths)
        let pathLine = pathLine(paths)
        let home = FileManager.default.homeDirectoryForCurrentUser
        for name in [".zprofile", ".zshrc"] {
            let file = home.appendingPathComponent(name)
            let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            guard !existing.contains(pathLine) else { continue }
            let block = (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n")
                + "\n# opProxy: its `op` asks you before agents read 1Password secrets.\n\(pathLine)\n"
            try (existing + block).write(to: file, atomically: true, encoding: .utf8)
        }
    }
}

/// The Setup window. One at a time; reopening brings it forward.
final class SetupWindow {
    private static var current: NSWindow?

    static func show(paths: Paths, pairing: CloudPairing?) {
        if let window = current {
            window.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SetupView(paths: paths, pairing: pairing)))
            window.title = "opProxy Setup"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            current = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SetupView: View {
    let paths: Paths
    let pairing: CloudPairing?
    @State private var realOp: String?
    @State private var shellOp: String?
    @State private var checked = false
    @State private var error: String?
    @State private var macName = ""

    private var executable: String { URL(fileURLWithPath: Bundle.main.executablePath ?? "").resolvingSymlinksInPath().path }
    private var shellReady: Bool { shellOp == executable }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("opProxy asks you before an AI agent reads a secret from 1Password.")
                .font(.headline)
            step(done: true, title: "opProxy runs in the background",
                 detail: "Its key in the menu bar shows how long 1Password's authorization has left.")
            step(done: realOp != nil, title: "The 1Password CLI is installed",
                 detail: realOp.map { "Found at \($0). In the 1Password app, turn on Settings → Developer → Integrate with 1Password CLI." }
                    ?? "Install it, then turn on Settings → Developer → Integrate with 1Password CLI in the 1Password app.") {
                if realOp == nil {
                    Button("How to install it") {
                        NSWorkspace.shared.open(URL(string: "https://developer.1password.com/docs/cli/get-started/")!)
                    }
                }
            }
            step(done: shellReady, title: "Terminals use opProxy's op",
                 detail: shellReady ? "New terminals and the agents started in them run opProxy's op."
                    : "New terminals run \(shellOp ?? "no op at all"). opProxy adds ~/.opProxy/bin to the start of your PATH in ~/.zprofile and ~/.zshrc. Agents already running keep their old PATH until restarted.") {
                if !shellReady {
                    Button("Add to my shell") {
                        do { try Setup.addToShell(executable: executable, paths: paths); check() } catch {
                            self.error = "Couldn't update your shell files: \(error)"
                        }
                    }
                }
            }
            if let pairing {
                step(done: nil, title: "Answer from your iPhone (optional)",
                     detail: "Install Secret Proxy on your iPhone, then pair it to answer requests there too. "
                        + "A phone paired with several Macs shows each request with its Mac's name.") {
                    HStack {
                        Text("This Mac's name")
                        TextField(Host.current().localizedName ?? "Mac", text: $macName)
                            .frame(width: 200)
                            .onSubmit(saveName)
                        Button("Save", action: saveName)
                    }
                    Button("Pair an iPhone…") { pairing.start() }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Text("opProxy \(MacIdentity.appVersion)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Check Again") { check() }
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear(perform: check)
    }

    private func saveName() {
        do { try OpProxyConfig.setMacName(macName, paths) } catch { self.error = "Couldn't save the name: \(error)" }
    }

    private func check() {
        macName = OpProxyConfig.load(paths)?.macName ?? ""
        realOp = Setup.realOp(paths)
        DispatchQueue.global().async {
            let found = Setup.shellOp()
            DispatchQueue.main.async { shellOp = found }
        }
    }

    /// One row: a tick, a dot for an optional step, or an empty circle.
    private func step(done: Bool?, title: String, detail: String,
                      @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done == true ? "checkmark.circle.fill" : done == nil ? "circle.dotted" : "circle")
                .font(.title2)
                .foregroundStyle(done == true ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                action()
            }
        }
    }
}
