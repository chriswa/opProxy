import Foundation

/// Which Mac this is, for a phone paired with several: a random ID made once (its zone on the
/// phone is named after it), and a name people choose in Setup, the computer's name until then.
public struct MacIdentity: Equatable {
    public let id: String
    public let name: String
    /// This build's version, which the iPhone app's should match.
    public let version: String

    public static func current(_ paths: Paths) -> MacIdentity {
        MacIdentity(id: id(paths), name: OpProxyConfig.load(paths)?.macName ?? Host.current().localizedName ?? "Mac",
                    version: appVersion)
    }

    /// The app bundle's version (the repo's VERSION), or "dev" for a bare binary. Found from
    /// the executable's real path, since `op` and `opProxy` run it through symlinks.
    public static var appVersion: String {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private static func id(_ paths: Paths) -> String {
        if let saved = try? String(contentsOf: paths.macID, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty { return saved }
        let made = UUID().uuidString.lowercased()
        try? paths.ensureStateDir()
        try? made.write(to: paths.macID, atomically: true, encoding: .utf8)
        return made
    }
}
