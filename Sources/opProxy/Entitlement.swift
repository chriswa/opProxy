import Foundation
import Security

/// This process's own code-signing entitlements.
enum Entitlement {
    static func strings(_ name: String) -> [String] {
        guard let task = SecTaskCreateFromSelf(nil) else { return [] }
        return SecTaskCopyValueForEntitlement(task, name as CFString, nil) as? [String] ?? []
    }
}
