import AppKit
import CoreGraphics

/// Context for why a 1Password CLI authorization ended. 1Password ends every CLI
/// authorization when the app locks, and the app locks on its own: after its idle timeout
/// (no keyboard or mouse input, regardless of CLI activity), on sleep, and on screen lock.
enum LockDiagnostics {
    /// 1Password's own log. Its lock lines read like
    /// `INFO  2026-10-02T16:02:53.149+00:00 ThreadId(10) [...lock.rs:282] Locked. Reason: Automatic(Idle(600)).`
    static let appLog = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Group Containers/2BUA8C4S2C.com.1password/Library/Application Support/1Password/Data/logs/1Password_rCURRENT.log")

    /// e.g. "1Password app Locked. Reason: Automatic(Idle(600)) at 09:02:53; no input for 15s".
    static func summary() -> String {
        [lastLockEvent(), "no input for \(Int(secondsSinceInput()))s"].compactMap { $0 }.joined(separator: "; ")
    }

    /// The most recent lock or unlock line in 1Password's log, in local time.
    static func lastLockEvent() -> String? {
        guard let handle = try? FileHandle(forReadingFrom: appLog) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 512_000 ? size - 512_000 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last {
            $0.contains("Locked. Reason:") || $0.contains("Lock state changed: Unlocked")
        }
        guard let line else { return nil }
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        let event = line.range(of: "] ", options: .backwards).map { String(line[$0.upperBound...]) } ?? String(line)
        let when = fields.count > 1 ? localTime(String(fields[1])) : nil
        return "1Password app " + event.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            + (when.map { " at \($0)" } ?? "")
    }

    private static func localTime(_ iso: String) -> String? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    /// Time since the last keyboard, mouse or trackpad input: what 1Password's idle lock counts.
    static func secondsSinceInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Logs sleep, wake and screen lock events, which each lock 1Password.
    static func logSystemEvents(to log: Log) -> [NSObjectProtocol] {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let events: [(NotificationCenter, Notification.Name, String)] = [
            (workspace, NSWorkspace.willSleepNotification, "Mac going to sleep"),
            (workspace, NSWorkspace.didWakeNotification, "Mac woke"),
            (workspace, NSWorkspace.screensDidSleepNotification, "display slept"),
            (workspace, NSWorkspace.screensDidWakeNotification, "display woke"),
            (distributed, Notification.Name("com.apple.screenIsLocked"), "screen locked"),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), "screen unlocked"),
        ]
        return events.map { center, name, text in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in log.write("system: \(text)") }
        }
    }
}
