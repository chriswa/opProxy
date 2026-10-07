import Foundation

/// Best-effort context about the requesting session. Every lookup quietly returns nil on failure.
public enum SessionInfo {
    // MARK: Transcripts

    /// The agent's latest assistant text. Agents write a tool call to the transcript only after
    /// it finishes, so this is the message before the one that triggered this request.
    public static func lastAgentMessage(_ session: AgentSession) -> String? {
        guard let url = transcriptURL(session) else { return nil }
        for line in tailLines(url, bytes: 512 * 1024).reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let text = assistantText(obj, agent: session.agent) { return text }
        }
        return nil
    }

    static func assistantText(_ obj: [String: Any], agent: AgentKind) -> String? {
        let blocks: [[String: Any]]
        switch agent {
        case .claude:
            guard obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return nil }
            blocks = content.filter { $0["type"] as? String == "text" }
        case .codex:
            guard obj["type"] as? String == "response_item",
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "message", payload["role"] as? String == "assistant",
                  let content = payload["content"] as? [[String: Any]] else { return nil }
            blocks = content
        case .cursor:
            return nil
        }
        let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func transcriptURL(_ session: AgentSession) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        switch session.agent {
        case .claude:
            let projects = home.appendingPathComponent(".claude/projects")
            guard let dirs = try? fm.contentsOfDirectory(atPath: projects.path) else { return nil }
            return dirs.lazy
                .map { projects.appendingPathComponent($0).appendingPathComponent(session.sessionId + ".jsonl") }
                .first { fm.fileExists(atPath: $0.path) }
        case .codex:
            // ~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<thread id>.jsonl; look back a week.
            let sessions = home.appendingPathComponent(".codex/sessions")
            let calendar = Calendar(identifier: .gregorian)
            for daysAgo in 0..<8 {
                guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) else { continue }
                let c = calendar.dateComponents([.year, .month, .day], from: day)
                let dir = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
                if let match = (try? fm.contentsOfDirectory(atPath: dir.path))?
                    .first(where: { $0.hasSuffix(session.sessionId + ".jsonl") }) {
                    return dir.appendingPathComponent(match)
                }
            }
            return nil
        case .cursor:
            return nil
        }
    }

    static func tailLines(_ url: URL, bytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        let data = handle.readDataToEndOfFile()
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if start > 0, !lines.isEmpty { lines.removeFirst() }  // partial line
        return lines
    }
}
