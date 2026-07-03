import Foundation

/// Parses a Claude Code transcript (.jsonl) into ordered conversational turns —
/// a Swift port of transcript-reader.py's `parse_conversation`. Tracks byte
/// offsets (append-only files) so the watcher can tell what it has already
/// spoken, plus the session entrypoint and background-work lifecycle so we can
/// stay silent for headless sessions and turns that only end to await async work.
struct Turn: Equatable, Codable, Sendable {
    let role: String          // "user" | "assistant"
    let text: String
    let pos: Int              // byte offset of the line
    let stopReason: String?   // assistant only: "end_turn" | "tool_use" | …
}

struct ParsedTranscript {
    let turns: [Turn]
    let completeBytes: Int
    let entrypoint: String?
    /// (byteOffset, delta): +1 where async work launches, −1 where it completes.
    let bgEvents: [(pos: Int, delta: Int)]
}

enum TranscriptParser {
    private static let bgLaunch = try! NSRegularExpression(
        pattern: "Command running in background with ID: ([a-z0-9]+)")
    private static let agentLaunchMark = "Async agent launched successfully"
    private static let agentID = try! NSRegularExpression(pattern: "agentId: ([a-z0-9]+)")
    private static let bgDone = try! NSRegularExpression(pattern: "<task-id>([a-z0-9]+)</task-id>")

    static func parse(data: Data) -> ParsedTranscript {
        guard let cut = data.lastIndex(of: 0x0A) else {
            return ParsedTranscript(turns: [], completeBytes: 0, entrypoint: nil, bgEvents: [])
        }
        let complete = data[...cut]
        var turns: [Turn] = []
        var launchPos: [String: Int] = [:]
        var donePos: [String: Int] = [:]
        var entrypoint: String?
        var pos = 0

        for lineData in complete.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let start = pos
            pos += lineData.count + 1
            guard !lineData.isEmpty else { continue }
            let lineText = String(decoding: lineData, as: UTF8.self)

            guard let event = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any]
            else { continue }

            if entrypoint == nil { entrypoint = event["entrypoint"] as? String }

            let kind = event["type"] as? String
            let message = event["message"] as? [String: Any]

            // Completion markers only from non-assistant lines (task notifications
            // are injected as user/system events), so the assistant's own words
            // can't spuriously complete a task.
            if kind != "assistant", lineText.contains("<status>") {
                let range = NSRange(lineText.startIndex..., in: lineText)
                for m in bgDone.matches(in: lineText, range: range) {
                    if let r = Range(m.range(at: 1), in: lineText) {
                        let tid = String(lineText[r]); donePos[tid] = donePos[tid] ?? start
                    }
                }
            }

            if kind == "assistant", let message {
                let text = textBlocks(message["content"])
                if !text.isEmpty {
                    turns.append(Turn(role: "assistant", text: text, pos: start,
                                      stopReason: message["stop_reason"] as? String))
                }
            } else if kind == "user", let message {
                let content = message["content"]
                if isToolResult(content) {
                    // Launch acks live ONLY in tool_result content. Scanning here
                    // (not raw text) prevents code/prose that merely mentions the
                    // phrase from registering a phantom, never-completing launch.
                    trackLaunches(in: toolResultText(content), start: start, launchPos: &launchPos)
                    continue
                }
                let text = textBlocks(content)
                if !text.isEmpty {
                    turns.append(Turn(role: "user", text: text, pos: start, stopReason: nil))
                }
            }
        }

        var events = launchPos.values.map { (pos: $0, delta: 1) }
        events += launchPos.compactMap { tid, _ in donePos[tid].map { (pos: $0, delta: -1) } }
        events.sort { $0.pos < $1.pos }
        return ParsedTranscript(turns: turns, completeBytes: complete.count,
                                entrypoint: entrypoint, bgEvents: events)
    }

    /// Concatenated text of a message's tool_result blocks (where background
    /// launch acknowledgements actually live).
    private static func toolResultText(_ content: Any?) -> String {
        guard let blocks = content as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for b in blocks where (b["type"] as? String) == "tool_result" {
            if let s = b["content"] as? String { parts.append(s) }
            else if let inner = b["content"] as? [[String: Any]] {
                for ib in inner where (ib["type"] as? String) == "text" {
                    if let t = ib["text"] as? String { parts.append(t) }
                }
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func trackLaunches(in text: String, start: Int, launchPos: inout [String: Int]) {
        guard !text.isEmpty else { return }
        let range = NSRange(text.startIndex..., in: text)
        // Require a corroborating phrase that only the genuine tool acknowledgement
        // carries, so a tool_result that merely *echoes* the bare phrase (a Read /
        // grep of code or a transcript) doesn't register a phantom launch.
        if text.contains("Output is being written to"),
           let m = bgLaunch.firstMatch(in: text, range: range),
           let r = Range(m.range(at: 1), in: text) {
            let id = String(text[r]); launchPos[id] = launchPos[id] ?? start
        } else if text.contains(agentLaunchMark), text.contains("agentId:"),
                  let m = agentID.firstMatch(in: text, range: range),
                  let r = Range(m.range(at: 1), in: text) {
            let id = String(text[r]); launchPos[id] = launchPos[id] ?? start
        }
    }

    private static func textBlocks(_ content: Any?) -> String {
        if let s = content as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block in
            (block["type"] as? String) == "text" ? (block["text"] as? String) : nil
        }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
         .filter { !$0.isEmpty }
         .joined(separator: "\n\n")
    }

    private static func isToolResult(_ content: Any?) -> Bool {
        guard let blocks = content as? [[String: Any]] else { return false }
        return blocks.contains { ($0["type"] as? String) == "tool_result" }
    }
}
