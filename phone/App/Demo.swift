import CloudKit
import FeedProtocol
import Foundation

/// A pretend Mac and its requests, for trying the app (App Review, say) without a Mac running
/// opProxy. Nothing reaches iCloud.
enum Demo {
    static let zone = CKRecordZone.ID(zoneName: CloudFeed.zoneName(macID: "demo"))

    static func mac(zone: CKRecordZone.ID = zone, name: String = "Demo Mac") -> MacFeed {
        let now = Date().timeIntervalSince1970 * 1000
        var mac = MacFeed(zoneID: zone, name: name)
        mac.pairedKeys = [PhoneKey.keyId]
        mac.version = FeedModel.appVersion
        mac.presenceAt = Date()
        mac.status = FeedProviderStatus(ok: true, label: "1Password", since: now - 3_600_000, until: now + 39_600_000,
                                        title: nil, detail: nil)
        return mac
    }

    /// A request like one a coding agent makes, timing out in 5 minutes.
    static func request(number: Int) -> FeedItem {
        let now = Date()
        let option = { (id: String, label: String, facets: [(String, String)], hint: String) -> [String: Any] in
            ["id": id, "label": label, "hint": hint, "facets": facets.map { ["name": $0.0, "value": $0.1] }]
        }
        let document: [String: Any] = [
            "tone": "caution",
            "title": "Engineering / GitHub token",
            "subtitle": "Claude Code Agent · session 4f2a91c0",
            "requester": ["name": "Claude Code Agent", "detail": "Session 4f2a91c0", "context": "in “fix flaky tests”"],
            "item": ["title": "GitHub token", "detail": "Vault: Engineering"],
            "context": [
                "command": "GH_TOKEN=$(op read 'op://Engineering/GitHub token/credential') gh pr checks 4127",
                "message": "CI is red on the pull request. I'll read the failing checks with the GitHub CLI to see which job broke.",
            ],
            "pickers": [[
                "id": "duration", "label": "Allow", "default": "once",
                "options": [
                    option("once", "Once", [("Allow", "Once")], "Runs this one request and remembers nothing."),
                    option("1d", "1 Day · This agent", [("Allow", "1 Day"), ("For", "This agent")], ""),
                    option("1d-all", "1 Day · All agents", [("Allow", "1 Day"), ("For", "All agents")], ""),
                    option("forever", "Forever · This agent", [("Allow", "Forever"), ("For", "This agent")], ""),
                    option("forever-all", "Forever · All agents", [("Allow", "Forever"), ("For", "All agents")], ""),
                ],
            ]],
            "actions": [["id": "deny", "label": "Deny", "role": "deny"], ["id": "approve", "label": "Allow", "role": "approve"]],
            "confirm": "Let Claude Code read “GitHub token”",
        ]
        let documentJSON = String(decoding: try! JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]), as: UTF8.self)
        let item: [String: Any] = [
            "id": "demo-\(number)", "revision": 1, "createdAt": now.timeIntervalSince1970 * 1000,
            "expiresAt": (now.timeIntervalSince1970 + 300) * 1000, "challenge": "{}", "document": documentJSON,
        ]
        return FeedItem.parse(String(decoding: try! JSONSerialization.data(withJSONObject: item), as: UTF8.self))!
    }
}
