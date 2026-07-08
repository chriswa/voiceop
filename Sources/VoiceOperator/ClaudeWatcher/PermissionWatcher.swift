import Foundation

/// Watches the spool directory that the `PermissionRequest` hook drops into, and
/// narrates a spoken summary the moment Claude blocks on a question
/// (`AskUserQuestion`) or a plan approval (`ExitPlanMode`).
///
/// This is the ONLY reliable signal for a pending block: Claude Code does not
/// flush the blocking tool_use to the transcript until the user answers, so the
/// transcript watcher can't see it while pending. The hook fires while it's
/// pending and carries the full content, so we narrate from that — combined with
/// the lead-up turns read from the session transcript (the messages the agent
/// sent during the turn before it asked), which ARE on disk.
actor PermissionWatcher {
    /// A parsed, narratable permission request. `content` is what to say —
    /// question prompts (options excluded) or the plan markdown (capped).
    struct PermissionEvent: Equatable {
        let toolName: String
        let sessionID: String?
        let transcriptPath: String?
        let content: String
    }

    private let registry: NameVoiceRegistry
    private let emit: @Sendable (Utterance, [Turn]) -> Void
    private let spoolDir: URL
    private let pollInterval: TimeInterval = 0.5
    private static let planCap = 6000

    init(registry: NameVoiceRegistry, spoolDir: URL,
         emit: @escaping @Sendable (Utterance, [Turn]) -> Void) {
        self.registry = registry
        self.spoolDir = spoolDir
        self.emit = emit
    }

    func start() { Task { await run() } }

    private func run() async {
        // Clear stragglers left while VO was down: a block answered in the
        // meantime must not be narrated stale (mirrors the transcript watcher's
        // "skip backlog, tail new activity"). New events arrive as we poll.
        drainStaleFiles()
        Log.log("permission: watching spool \(spoolDir.path)")
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(for: .seconds(pollInterval))
        }
    }

    private func drainStaleFiles() {
        for url in spoolFiles() { try? FileManager.default.removeItem(at: url) }
    }

    /// The `.json` files currently in the spool (ignores the hook's in-progress
    /// `tmp.XXXXXX` temp files), oldest first — names are timestamp-prefixed.
    private func spoolFiles() -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: spoolDir.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.sorted()
            .map { spoolDir.appendingPathComponent($0) }
    }

    private func tick() async {
        for url in spoolFiles() {
            defer { try? FileManager.default.removeItem(at: url) }   // consume-once
            guard let data = try? Data(contentsOf: url),
                  let event = Self.parse(eventData: data) else { continue }
            await narrate(event)
        }
    }

    private func narrate(_ event: PermissionEvent) async {
        guard let sid = event.sessionID else { return }

        // Lead-up context ("what's been done"): the turns since the last end_turn,
        // read from the transcript. The pending tool_use itself isn't there yet —
        // the hook supplies it as the synthetic final turn below.
        var context: [Turn] = []
        if let path = event.transcriptPath,
           let tdata = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            let parsed = TranscriptParser.parse(data: tdata)
            if let ep = parsed.entrypoint, ep.hasPrefix("sdk") { return }   // headless — stay silent
            context = Self.contextSinceLastEndTurn(parsed.turns)
        }
        context.append(Turn(role: "assistant", text: event.content, pos: Int.max, stopReason: "tool_use"))

        let key = NameVoiceRegistry.key(["claude": sid])
        guard let voice = await registry.assign(key) else { return }

        let kind = event.toolName == "ExitPlanMode" ? "plan approval" : "question"
        Log.log("permission: [\(sid.prefix(8))] pending \(kind) — speaking; summarizing \(context.count) turn(s)")
        let summary = await ClaudeSummarizer.summarize(context: context, spoken: [])
        Log.log("permission: [\(sid.prefix(8))] \(voice.name): \(summary.prefix(60))")
        emit(Utterance(name: voice.name, body: summary, voiceID: voice.voiceID, sessionKey: sid), context)
    }

    // MARK: - Pure helpers (unit-tested)

    /// Parse a spool file (`{ receivedAt, payload: <hook json> }`) into a
    /// narratable event, or nil if it isn't a question/plan we handle. The
    /// answer OPTIONS are deliberately excluded; the plan is capped.
    static func parse(eventData data: Data, planCap: Int = planCap) -> PermissionEvent? {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = event["payload"] as? [String: Any],
              let toolName = payload["tool_name"] as? String,
              let toolInput = payload["tool_input"] as? [String: Any],
              let content = spokenContent(toolName: toolName, toolInput: toolInput, planCap: planCap)
        else { return nil }
        return PermissionEvent(toolName: toolName,
                               sessionID: payload["session_id"] as? String,
                               transcriptPath: payload["transcript_path"] as? String,
                               content: content)
    }

    /// The text to narrate for a tool, or nil for tools we don't announce.
    static func spokenContent(toolName: String, toolInput: [String: Any], planCap: Int) -> String? {
        switch toolName {
        case "AskUserQuestion":
            let qs = (toolInput["questions"] as? [[String: Any]])?
                .compactMap { ($0["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
            return qs.isEmpty ? nil : qs.joined(separator: "\n")
        case "ExitPlanMode":
            guard let plan = (toolInput["plan"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty else { return nil }
            return String(plan.prefix(planCap))
        default:
            return nil   // other permission prompts (Bash/Edit/…) are not announced
        }
    }

    /// The turns since the last completed (`end_turn`) assistant turn — the
    /// lead-up the agent produced during the current turn before it blocked.
    static func contextSinceLastEndTurn(_ turns: [Turn]) -> [Turn] {
        guard !turns.isEmpty else { return [] }
        var i = turns.count - 1
        while i >= 0 && !(turns[i].role == "assistant" && turns[i].stopReason == "end_turn") { i -= 1 }
        return Array(turns[(i + 1)...])
    }
}
