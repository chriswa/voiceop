import Foundation

/// Resolves a Claude Code session id → spaceterm surface (pty session) id by
/// reading spaceterm's state.json. Each terminal node records the Claude
/// sessions it has hosted under `terminalSessions[].claudeSessionId`; the node's
/// own `id` is the surface id that `focus-surface-request` expects.
///
/// Read on demand (only when a dictation matches an active call-sign), so the
/// 5 MB state file isn't parsed on every dictation.
enum SpacetermSurfaceResolver {
    private static var statePath: String {
        let dir = ProcessInfo.processInfo.environment["SPACETERM_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".spaceterm")
        return (dir as NSString).appendingPathComponent("state.json")
    }

    static func surfaceId(forClaudeSession claudeSessionID: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodes = root["nodes"] as? [String: Any] else { return nil }

        // The server focuses by the terminal's CURRENT pty session id, which is
        // node.sessionId — this diverges from node.id after a terminal restart,
        // so we must use sessionId, not id. Prefer an alive node (a claude session
        // id can appear in several terminals' history via forks/restarts).
        var fallback: String?
        for (nodeID, value) in nodes {
            guard let node = value as? [String: Any],
                  node["type"] as? String == "terminal",
                  let sessions = node["terminalSessions"] as? [[String: Any]],
                  sessions.contains(where: { ($0["claudeSessionId"] as? String) == claudeSessionID })
            else { continue }
            let surface = node["sessionId"] as? String ?? node["id"] as? String ?? nodeID
            if node["alive"] as? Bool == true { return surface }
            fallback = fallback ?? surface
        }
        return fallback
    }
}
