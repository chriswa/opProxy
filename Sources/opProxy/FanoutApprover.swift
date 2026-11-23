import Foundation

/// The Mac's own way of answering: the dialog, or a scripted stand-in in tests.
protocol LocalApprover: Approver {
    /// Called once `key`'s dialog is on screen, with when it will time out. Requests queue
    /// behind the one showing, so this can be well after `requestApproval`.
    var onCountdown: ((DialogKey, Date) -> Void)? { get set }
    /// `key` was answered elsewhere: close or unqueue its dialog. Its completion may still be
    /// called afterwards (the scripted approver can't take its answer back); it is ignored.
    func dismiss(_ key: DialogKey)
}

/// Asks on the Mac, and on the approval feed too if the Mac hasn't answered within
/// `phoneDelay`. Whichever answers first decides; the other side is then dismissed, and
/// anything it says later is ignored.
final class FanoutApprover: Approver {
    /// How long the Mac alone is asked before phones are too.
    static let defaultPhoneDelay: TimeInterval = 30

    private let local: LocalApprover
    private let feed: ApprovalFeed
    private let phoneDelay: TimeInterval

    init(local: LocalApprover, feed: ApprovalFeed, phoneDelay: TimeInterval = defaultPhoneDelay) {
        self.local = local
        self.feed = feed
        self.phoneDelay = phoneDelay
        local.onCountdown = { [feed] key, deadline in feed.countdown(key, until: deadline) }
    }

    func requestApproval(_ prompt: ApprovalPrompt, completion: @escaping (Decision) -> Void) {
        // Called from the main queue (dialog), the feed's queue (phone) and, in tests, any queue.
        let lock = NSLock()
        var decided = false
        let claim = { lock.withLock { () -> Bool in
            defer { decided = true }
            return !decided
        } }
        let id = feed.publish(prompt, after: phoneDelay) { [local] decision in
            guard claim() else { return false }
            local.dismiss(prompt.key)
            completion(decision)
            return true
        }
        local.requestApproval(prompt) { [feed] decision in
            guard claim() else { return }
            feed.remove(id, note: Self.macNote(decision))
            completion(decision)
        }
    }

    func requestersLeft(_ key: DialogKey) {
        local.requestersLeft(key)
        feed.requestersLeft(key)
    }

    private static func macNote(_ decision: Decision) -> String {
        switch decision {
        case .approved: return "Allowed on the Mac"
        case .denied: return "Denied on the Mac"
        case .timedOut: return "Timed out"
        }
    }
}
