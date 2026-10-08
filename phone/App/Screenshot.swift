#if DEBUG
import Foundation

/// Screens to open for README and App Store screenshots in the simulator, which has no iCloud
/// account: launch with `-shot <name>`. Debug builds only.
enum Screenshot: String {
    case pairing, guide, confirm, request, allowed, macs

    static var current: Screenshot? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-shot"), i + 1 < arguments.count else { return nil }
        return Screenshot(rawValue: arguments[i + 1])
    }
}
#endif
