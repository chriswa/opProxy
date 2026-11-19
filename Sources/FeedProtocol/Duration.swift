import Foundation

/// Spans of time as the Mac's menu bar and the phone's status bar show them.
public enum Duration {
    /// Rounded to the nearest whole unit, counting down: "12h" from 11h 30m up, then "59m"
    /// to "1m", then "59s" to "0s". A unit never rounds up into the next ("60m" is "59m").
    public static func short(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds >= 3600 { return "\(Int((seconds / 3600).rounded()))h" }
        if seconds >= 60 { return "\(min(59, Int((seconds / 60).rounded())))m" }
        return "\(min(59, Int(seconds.rounded())))s"
    }

    /// Whole hours so far, counting up: "0h" for the first hour, then "1h", … "141h".
    public static func hours(_ seconds: TimeInterval) -> String {
        "\(Int(max(0, seconds) / 3600))h"
    }
}
