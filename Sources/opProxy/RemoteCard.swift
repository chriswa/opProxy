import Foundation
import OpProxyCore

/// The approval dialog as an approval feed document (APPROVAL_FEED.md): the same facts, in
/// the same order, for the phone to render. Built from the same prompt and options.
enum RemoteCard {
    static let picker = "duration"
    static let abandonedNotice = "The agent stopped waiting. Approving still lets its retry through."

    static func document(_ prompt: ApprovalPrompt, options: [ApprovalOption], defaultIndex: Int, abandoned: Bool) -> String {
        var doc: [String: Any] = [
            "tone": "caution",
            "kicker": "1Password security approval",
            "title": prompt.target.label,
            "subtitle": subtitle(prompt.requester),
            "sections": sections(prompt),
            "pickers": [[
                "id": picker, "label": "Allow", "default": options[defaultIndex].id,
                "options": options.map { ["id": $0.id, "label": $0.label, "hint": $0.hint] },
            ]],
            "actions": [
                ["id": "deny", "label": "Deny", "role": "deny"],
                ["id": "approve", "label": "Approve", "role": "approve"],
            ],
            "confirm": prompt.touchIDReason.prefix(1).uppercased() + prompt.touchIDReason.dropFirst(),
        ]
        if let surface = prompt.requester.surface { doc["surfaceId"] = surface.nodeId }
        if abandoned { doc["notice"] = abandonedNotice }
        let data = try! JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func subtitle(_ requester: Requester) -> String {
        switch requester {
        case .agent(let a):
            return requester.name + " · " + (a.surface?.title.map { "“\($0)”" } ?? "untitled session")
        case .terminal(let t):
            return ([requester.name, "terminal tab"] + [t.info.tty, t.surface?.title.map { "“\($0)”" }].compactMap { $0 })
                .joined(separator: " · ")
        }
    }

    private static func sections(_ prompt: ApprovalPrompt) -> [[String: Any]] {
        func row(_ label: String, _ value: String, mono: Bool = false) -> [String: Any] {
            mono ? ["label": label, "value": value, "mono": true] : ["label": label, "value": value]
        }
        func text(_ label: String, _ text: String, mono: Bool) -> [String: Any] {
            mono ? ["kind": "text", "label": label, "text": text, "mono": true] : ["kind": "text", "label": label, "text": text]
        }
        var request = [row("Request", prompt.item.action)] + prompt.item.details.map { row($0.label, $0.value) }
        request += [row("Item ID", prompt.target.itemId, mono: true), row("Vault ID", prompt.target.vaultId, mono: true)]
        var sections: [[String: Any]] = []
        sections.append(["kind": "fields", "label": "Request", "rows": request])
        sections.append(text("Command", "op " + prompt.request.argv.map(shellQuote).joined(separator: " "), mono: true))
        var process: [[String: Any]]
        switch prompt.requester {
        case .agent(let a):
            if let tool = a.caller.toolCommand { sections.append(text("Agent's shell command", tool, mono: true)) }
            if let message = a.lastMessage { sections.append(text("Agent's last message", message, mono: false)) }
            process = [
                row("Session ID", a.session.sessionId, mono: true),
                row("Agent process", "\(a.session.agent.displayName) · PID \(a.agentPid)", mono: true),
                row("Requested by", "PID \(prompt.peerPid)", mono: true),
                row("Directory", prompt.request.cwd, mono: true),
            ]
            if let via = a.caller.viaProcess { process.append(row("Called by", String(via.prefix(300)), mono: true)) }
        case .terminal(let t):
            sections.append(text("Process chain (nearest first)", t.info.chain.joined(separator: "\n"), mono: true))
            process = [
                row("Terminal", t.info.app + (t.info.tty.map { " · \($0)" } ?? ""), mono: true),
                row("Tab session", "Unix session \(t.info.sid)", mono: true),
                row("Requested by", "PID \(prompt.peerPid)", mono: true),
                row("Directory", prompt.request.cwd, mono: true),
            ]
        }
        sections.append(["kind": "fields", "label": "Process", "rows": process])
        return sections
    }
}
