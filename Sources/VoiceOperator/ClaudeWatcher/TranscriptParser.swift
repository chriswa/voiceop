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

/// A background launch observed in the transcript. `donePos` is nil when no
/// completion notification has been recorded — which happens not only while
/// the work runs, but forever if it was killed or finished while the session
/// sat idle (the harness never persists a notification in those cases). Each
/// kind has a different liveness probe the watcher uses to resolve launches
/// the transcript never will; see TranscriptWatcher.resolveOrphanedLaunches.
struct BackgroundLaunch: Sendable {
    enum Kind: Sendable { case bash, agent, monitor, workflow }
    let id: String
    let kind: Kind
    let pos: Int              // byte offset of the launch ack
    let outputPath: String?   // bash only: the file its process tree holds open
    let runID: String?        // workflow only: the wf_… id keying its state file
    let donePos: Int?         // byte offset of the completion notification

    init(id: String, kind: Kind, pos: Int, outputPath: String? = nil,
         runID: String? = nil, donePos: Int?) {
        self.id = id; self.kind = kind; self.pos = pos
        self.outputPath = outputPath; self.runID = runID; self.donePos = donePos
    }
}

struct ParsedTranscript {
    let turns: [Turn]
    let completeBytes: Int
    let entrypoint: String?
    let launches: [BackgroundLaunch]
}

enum TranscriptParser {
    // The Bash id and output path are matched as one sentence pair: only the
    // genuine tool acknowledgement carries both, so a tool_result that merely
    // *echoes* the bare launch phrase (a Read / grep of code or a transcript)
    // doesn't register a phantom, never-completing launch — and every
    // registered Bash launch has a path the watcher can probe for liveness.
    private static let bgLaunch = try! NSRegularExpression(
        pattern: "Command running in background with ID: ([a-z0-9]+)\\. Output is being written to: (.+?\\.output)")
    private static let agentLaunchMark = "Async agent launched successfully"
    private static let agentID = try! NSRegularExpression(pattern: "agentId: ([a-z0-9]+)")
    // "(task <id>, timeout Nms)" or "(task <id>)" — persistent monitors omit the timeout.
    private static let monitorLaunch = try! NSRegularExpression(
        pattern: "Monitor started \\(task ([a-z0-9]+)[,)]")
    // A genuine workflow ack carries both the task id (what notifications key
    // on) and the run id (what the on-disk state file is named after). Both
    // are required to register — which also hardens against echoed fragments.
    private static let workflowLaunch = try! NSRegularExpression(
        pattern: "Workflow launched in background\\. Task ID: ([a-z0-9]+)")
    private static let workflowRunID = try! NSRegularExpression(
        pattern: "Run ID: (wf_[a-z0-9-]+)")
    // A successful SendMessage to a background agent RE-ACTIVATES it with no
    // new launch ack (and resolves name-addressed sends to the canonical id in
    // its result text) — so a success result re-opens that id's ledger entry.
    // Primary signal: the structured `resumedAgentId` field (verified live,
    // 2.1.201). Fallback: the `Agent "<id>"` message phrase, whose wording
    // varies by resume path ("was stopped (completed); resumed it…" vs "had no
    // active task; resumed from transcript…") but always leads with the id.
    // The result payload is a JSON document carried as tool_result text, so
    // quotes inside it may still be backslash-escaped when scanned.
    private static let resumedAgentID = try! NSRegularExpression(
        pattern: "\\\\?\"resumedAgentId\\\\?\"\\s*:\\s*\\\\?\"([a-z0-9]+)\\\\?\"")
    private static let agentResumed = try! NSRegularExpression(
        pattern: "Agent \\\\?\"([a-z0-9]+)\\\\?\"")
    // Completion requires <status> on the same line: a persistent monitor's
    // per-EVENT notifications carry <task-id> but no <status>, and must not
    // resolve the launch.
    private static let bgDone = try! NSRegularExpression(pattern: "<task-id>([a-z0-9]+)</task-id>")

    static func parse(data: Data) -> ParsedTranscript {
        guard let cut = data.lastIndex(of: 0x0A) else {
            return ParsedTranscript(turns: [], completeBytes: 0, entrypoint: nil, launches: [])
        }
        let complete = data[...cut]
        var turns: [Turn] = []
        var launchPos: [String: (kind: BackgroundLaunch.Kind, pos: Int, path: String?, runID: String?)] = [:]
        var donePositions: [String: [Int]] = [:]   // ascending (scan order)
        var resumptions: [(id: String, pos: Int)] = []
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
                        donePositions[String(lineText[r]), default: []].append(start)
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
                    let text = toolResultText(content)
                    trackLaunches(in: text, start: start, launchPos: &launchPos)
                    trackResumptions(in: text, start: start, resumptions: &resumptions)
                    continue
                }
                let text = textBlocks(content)
                if !text.isEmpty {
                    turns.append(Turn(role: "user", text: text, pos: start, stopReason: nil))
                }
            }
        }

        // Completions are attached per-launch (never emitted standalone), so a
        // stray notification for a task we never saw launch can't affect
        // counts. Each launch pairs with the first completion AFTER it: an
        // agent resumed via SendMessage is a fresh entry for the same id, and
        // must not be resolved by the completion of its previous run (nor any
        // launch by a notification echoed before it).
        var launches = launchPos.map { id, launch in
            BackgroundLaunch(id: id, kind: launch.kind, pos: launch.pos,
                             outputPath: launch.path, runID: launch.runID,
                             donePos: donePositions[id]?.first { $0 > launch.pos })
        }
        launches += resumptions.map { r in
            BackgroundLaunch(id: r.id, kind: .agent, pos: r.pos,
                             donePos: donePositions[r.id]?.first { $0 > r.pos })
        }
        launches.sort { $0.pos < $1.pos }
        return ParsedTranscript(turns: turns, completeBytes: complete.count,
                                entrypoint: entrypoint, launches: launches)
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

    private static func trackLaunches(in text: String, start: Int,
                                      launchPos: inout [String: (kind: BackgroundLaunch.Kind, pos: Int, path: String?, runID: String?)]) {
        guard !text.isEmpty else { return }
        let range = NSRange(text.startIndex..., in: text)
        if let m = bgLaunch.firstMatch(in: text, range: range),
           let idRange = Range(m.range(at: 1), in: text),
           let pathRange = Range(m.range(at: 2), in: text) {
            let id = String(text[idRange])
            launchPos[id] = launchPos[id] ?? (.bash, start, String(text[pathRange]), nil)
        } else if text.contains(agentLaunchMark), text.contains("agentId:"),
                  let m = agentID.firstMatch(in: text, range: range),
                  let r = Range(m.range(at: 1), in: text) {
            let id = String(text[r]); launchPos[id] = launchPos[id] ?? (.agent, start, nil, nil)
        } else if let m = monitorLaunch.firstMatch(in: text, range: range),
                  let r = Range(m.range(at: 1), in: text) {
            let id = String(text[r]); launchPos[id] = launchPos[id] ?? (.monitor, start, nil, nil)
        } else if let m = workflowLaunch.firstMatch(in: text, range: range),
                  let idRange = Range(m.range(at: 1), in: text),
                  let rm = workflowRunID.firstMatch(in: text, range: range),
                  let runRange = Range(rm.range(at: 1), in: text) {
            let id = String(text[idRange])
            launchPos[id] = launchPos[id] ?? (.workflow, start, nil, String(text[runRange]))
        }
    }

    /// A SendMessage tool_result with `success: true` re-activates the quoted
    /// (canonical, CLI-resolved) agent id with no new launch ack — a real
    /// false-idle bug source. A send to a still-running agent also succeeds;
    /// the extra entry is harmless since it pairs with the same next
    /// completion. Phantom entries from echoed results self-heal via the
    /// watcher's agent-tail probe.
    private static let sendSuccess = try! NSRegularExpression(pattern: "\"success\"\\s*:\\s*true")

    private static func trackResumptions(in text: String, start: Int,
                                         resumptions: inout [(id: String, pos: Int)]) {
        guard !text.isEmpty, text.contains("\"success\"") else { return }
        let range = NSRange(text.startIndex..., in: text)
        guard sendSuccess.firstMatch(in: text, range: range) != nil else { return }
        let match = resumedAgentID.firstMatch(in: text, range: range)
            ?? agentResumed.firstMatch(in: text, range: range)
        guard let m = match, let r = Range(m.range(at: 1), in: text) else { return }
        resumptions.append((id: String(text[r]), pos: start))
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
