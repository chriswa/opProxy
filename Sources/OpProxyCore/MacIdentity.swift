import Foundation

/// Which Mac this is, for a phone paired with several: a random ID made once (its zone on the
/// phone is named after it), and a name people choose in Setup, the computer's name until then.
public struct MacIdentity: Equatable {
    public let id: String
    public let name: String

    public static func current(_ paths: Paths) -> MacIdentity {
        MacIdentity(id: id(paths), name: OpProxyConfig.load(paths)?.macName ?? Host.current().localizedName ?? "Mac")
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
