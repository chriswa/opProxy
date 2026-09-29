import Foundation

/// Environment overrides for tests (`OPPROXY_*`). Always nil in release builds.
public enum TestKnobs {
    public static func value(_ name: String, in env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        #if OPPROXY_TESTING
        return env[name].flatMap { $0.isEmpty ? nil : $0 }
        #else
        return nil
        #endif
    }

    public static var enabled: Bool {
        #if OPPROXY_TESTING
        return true
        #else
        return false
        #endif
    }
}
