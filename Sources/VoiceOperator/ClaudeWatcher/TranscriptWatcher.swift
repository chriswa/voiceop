import Foundation

/// Watches every Claude Code transcript and enqueues a spoken summary for each
/// completed assistant turn — a Swift port of transcript-reader.py's watch loop.
/// Assigns a sticky name+voice per session, mutes headless (`sdk*`) sessions and
/// turns that only ended to await background work, and prefixes each update with
/// the call-sign ("Waldo here. …").
actor TranscriptWatcher {
    private struct SessionState {
        var size: Int
        var consumed: Int
        var voice: NamedVoice?
        var spoken: [String] = []
        var muted = false
    }
    private struct Pending { var size: Int; var changed: Date; var first: Date }

    private let registry: NameVoiceRegistry
    private let emit: @Sendable (Utterance, [Turn]) -> Void
    /// Fired around each Haiku summarization (true=started, false=finished) so the
    /// menu-bar icon can show the shared blue "waiting on Claude" state.
    private let onClaudeThinking: (@Sendable (Bool) -> Void)?
    private var states: [String: SessionState] = [:]
    private var pending: [String: Pending] = [:]
    /// Launch ids verified dead by a liveness probe (see
    /// `resolveOrphanedLaunches`). Bash tasks and monitors can't come back, so
    /// their verdicts cache forever. Agents CAN be resumed (the same task-id
    /// notifies again), so agent verdicts are recomputed per change instead.
    private var resolvedDead: Set<String> = []
    /// Agent-probe verdicts already logged (log dedup only — the verdicts
    /// themselves are deliberately recomputed per change; see above).
    private var loggedAgentProbes: Set<String> = []

    private let pollInterval: TimeInterval = 0.5
    private let settleSeconds: TimeInterval = 2.5
    private let maxSettleWait: TimeInterval = 20
    /// Grace period after a turn looks settled before we narrate it, to catch a
    /// prompt the user had QUEUED being pushed straight back to the agent the
    /// instant it settled (see the recheck in `handleChange`).
    private let settleRecheckDelay: TimeInterval = 0.25
    private let spokenHistory = 10
    private let idleTTL: TimeInterval = 30 * 60   // release name/voice after 30m idle

    init(registry: NameVoiceRegistry,
         onClaudeThinking: (@Sendable (Bool) -> Void)? = nil,
         emit: @escaping @Sendable (Utterance, [Turn]) -> Void) {
        self.registry = registry
        self.onClaudeThinking = onClaudeThinking
        self.emit = emit
    }

    func start() {
        Task { await run() }
    }

    private func run() async {
        // Baseline everything present at startup: skip backlog, tail from here.
        for path in Self.transcriptPaths() {
            if let size = Self.fileSize(path) {
                states[path] = SessionState(size: size, consumed: size)
            }
        }
        Log.log("watcher: watching \(states.count) transcript(s); tailing new activity")

        while !Task.isCancelled {
            let now = Date()
            let current = Set(Self.transcriptPaths())
            states.keys.filter { !current.contains($0) }.forEach { states[$0] = nil }
            pending.keys.filter { !current.contains($0) }.forEach { pending[$0] = nil }

            for path in current {
                guard let size = Self.fileSize(path) else { continue }
                if var state = states[path] {
                    if size == state.size { continue }
                    if size < state.size { state.consumed = 0 }  // truncated/replaced
                    state.size = size
                    states[path] = state
                    await handleChange(path)
                } else {
                    settleNewFile(path, size: size, now: now)
                }
            }
            await registry.reapIdle(ttl: idleTTL)
            try? await Task.sleep(for: .seconds(pollInterval))
        }
    }

    /// A file that appeared after startup is baselined once its size settles, so
    /// a forked session's copied history is skipped, not read as new activity.
    private func settleNewFile(_ path: String, size: Int, now: Date) {
        guard var p = pending[path] else {
            pending[path] = Pending(size: size, changed: now, first: now)
            return
        }
        if size != p.size { p.size = size; p.changed = now }
        guard now.timeIntervalSince(p.changed) >= settleSeconds
            || now.timeIntervalSince(p.first) >= maxSettleWait else {
            pending[path] = p
            return
        }
        states[path] = SessionState(size: size, consumed: size)
        pending[path] = nil

        // Baselining at the tail is how a forked session's copied history is
        // skipped — but the guard can't tell a fork from a genuine new session
        // whose first turn completed inside the settle window (both just look
        // like "content appeared, then went quiet"), so it silently discards
        // that first turn. Any completed turn present at baseline is a turn we
        // will NEVER narrate; log it so the loss is one grep away instead of a
        // reconstruction from restart timestamps. (The real fix — distinguish
        // fork from live by content age, not size — is still pending.)
        let sid = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
        let completed = (try? Data(contentsOf: URL(fileURLWithPath: path))).map {
            TranscriptParser.parse(data: $0).turns
                .filter { $0.role == "assistant" && $0.stopReason == "end_turn" }.count
        } ?? 0
        if completed > 0 {
            Log.log("watcher: [\(sid.prefix(8))] baselined new transcript at \(size) bytes — skipping \(completed) already-complete turn(s) as presumed fork history; a genuine new session's first turn is indistinguishable here and would be lost the same way")
        } else {
            Log.log("watcher: [\(sid.prefix(8))] baselined new transcript at \(size) bytes; tailing new activity")
        }
    }

    private func handleChange(_ path: String) async {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        let parsed = TranscriptParser.parse(data: data)
        let sid = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
        guard var state = states[path] else { return }

        // Mute headless / SDK-launched sessions (claude -p, subagents, our own
        // summarizer). Still advance consumed so the session is treated as handled.
        if let ep = parsed.entrypoint, ep.hasPrefix("sdk") {
            if !state.muted { state.muted = true; Log.log("watcher: muting \(sid.prefix(8)) (headless entrypoint: \(ep))") }
            state.consumed = max(state.consumed, parsed.completeBytes)
            states[path] = state
            return
        }

        if state.voice == nil {
            state.voice = await registry.assign(NameVoiceRegistry.key(["claude": sid]))
        } else {
            await registry.touch(NameVoiceRegistry.key(["claude": sid]))
        }
        guard let voice = state.voice else { states[path] = state; return }

        let turns = parsed.turns
        var resolved: Set<String>? = nil
        for (i, turn) in turns.enumerated() {
            guard turn.role == "assistant", turn.pos >= state.consumed,
                  turn.stopReason == "end_turn" else { continue }

            // A settled turn is only worth narrating if it's the session's
            // terminal state. A user turn after it means a prompt — usually one
            // the user had QUEUED — re-engaged the agent the instant it settled,
            // so the turn was a transient stop, not a real one. Nothing but a
            // user turn can follow a genuine end_turn, so its presence is the
            // exact test. Catch it in two moments; moment one: the prompt
            // already landed in this same batch (no wait needed).
            if Self.userTurnLanded(after: turn.pos, in: turns) {
                Log.log("watcher: [\(sid.prefix(8))] suppressing settled turn at pos \(turn.pos) — a queued prompt already landed after it in the same batch")
                continue
            }

            // Suppress turns while background work is still outstanding — but
            // trust the transcript only where it resolves a launch itself.
            // Probing is deferred until a completed turn is actually at stake,
            // and run once per change batch (lsof scans every process).
            if resolved == nil {
                resolved = resolveOrphanedLaunches(parsed.launches, sid: sid, transcriptPath: path)
            }
            let outstanding = Self.outstandingCount(parsed.launches, before: turn.pos,
                                                    resolved: resolved ?? [])
            if outstanding > 0 {
                Log.log("watcher: [\(sid.prefix(8))] skipped a completed turn — \(outstanding) background task(s) still outstanding")
                continue
            }

            // Moment two: the turn is currently the tail, so wait a beat and
            // re-read — a queued prompt injected in the window between the
            // settle and our narration would land as a fresh user turn.
            try? await Task.sleep(for: .seconds(settleRecheckDelay))
            if let fresh = try? Data(contentsOf: URL(fileURLWithPath: path)),
               Self.userTurnLanded(after: turn.pos, in: TranscriptParser.parse(data: fresh).turns) {
                Log.log("watcher: [\(sid.prefix(8))] suppressing settled turn at pos \(turn.pos) — a queued prompt landed within \(Int(settleRecheckDelay * 1000))ms of it settling")
                continue
            }

            // Context = turns since the previous end-of-turn marker.
            var prev = i - 1
            while prev >= 0 && !(turns[prev].role == "assistant" && turns[prev].stopReason == "end_turn") {
                prev -= 1
            }
            let context = Array(turns[(prev + 1)...i])
            // The decision to speak is made HERE — the summary line below lands
            // seconds later (LLM latency), so post-incident forensics need this
            // timestamp, not that one.
            Log.log("watcher: [\(sid.prefix(8))] turn at pos \(turn.pos) has no outstanding background work — speaking; summarizing \(context.count) turn(s)")
            onClaudeThinking?(true)
            let summary = await ClaudeSummarizer.summarize(context: context, spoken: state.spoken)
            onClaudeThinking?(false)
            Log.log("watcher: [\(sid.prefix(8))] \(voice.name): \(summary.prefix(60))")
            emit(Utterance(name: voice.name, body: summary, voiceID: voice.voiceID, sessionKey: sid), context)
            state.spoken.append(summary)
            if state.spoken.count > spokenHistory { state.spoken.removeFirst(state.spoken.count - spokenHistory) }
        }
        state.consumed = max(state.consumed, parsed.completeBytes)
        states[path] = state
    }

    // MARK: - Background-work liveness

    /// The transcript alone can't be trusted to resolve every launch: the
    /// harness never persists a completion notification for work that was
    /// killed or that finished while the session sat idle, so one orphaned
    /// launch would otherwise mute a session's narration forever. Each kind
    /// gets the strongest probe it supports (all verified live 2026-07-06):
    ///  - bash: its process tree holds the `.output` file open until it exits.
    ///  - agent: runs inside the CLI (no fd to probe), but its subagent
    ///    transcript's last assistant event flips tool_use → end_turn when it
    ///    finishes. Agents can be resumed, so this verdict is never cached.
    ///  - monitor: its stdout is piped to the CLI (`.output` is NOT held), but
    ///    every shell the session spawns carries CLAUDE_SESSION_ID=<sid> in its
    ///    argv — no such process means every monitor of the session is dead.
    ///  - workflow: in-process, but the harness writes a per-run state file
    ///    (workflows/<runId>.json, status + full result) the moment the run
    ///    ends. Absent while running, present once finished.
    /// Returns the full resolved id set for this pass (cached + agent verdicts).
    private func resolveOrphanedLaunches(_ launches: [BackgroundLaunch], sid: String,
                                         transcriptPath: String) -> Set<String> {
        var resolved = resolvedDead
        var sessionShellsAlive: Bool?
        // Queued-but-undelivered launches are never probed: the work IS
        // finished, but outstandingCount must keep muting until delivery.
        for launch in launches where launch.donePos == nil && launch.queuedPos == nil
            && !resolved.contains(launch.id) {
            switch launch.kind {
            case .bash:
                guard let path = launch.outputPath, !Self.isFileHeldOpen(path) else { continue }
            case .monitor:
                let alive = sessionShellsAlive ?? Self.sessionHasLiveShells(sid: sid)
                sessionShellsAlive = alive
                guard !alive else { continue }
            case .agent:
                let sub = Self.subagentTranscriptPath(transcriptPath: transcriptPath,
                                                      sid: sid, agentID: launch.id)
                guard Self.agentFinished(subagentTranscript: sub) else { continue }
                resolved.insert(launch.id)   // resumable — don't cache
                if loggedAgentProbes.insert(launch.id).inserted {
                    Log.log("watcher: [\(sid.prefix(8))] agent \(launch.id) probe: subagent transcript shows end_turn — treating as finished (rechecked per change; agents can resume)")
                }
                continue
            case .workflow:
                guard let runID = launch.runID,
                      FileManager.default.fileExists(
                        atPath: Self.workflowStateFilePath(transcriptPath: transcriptPath,
                                                           sid: sid, runID: runID))
                else { continue }
            }
            resolvedDead.insert(launch.id)
            resolved.insert(launch.id)
            Log.log("watcher: [\(sid.prefix(8))] background \(launch.kind) \(launch.id) is no longer running — treating as finished despite no completion notification")
        }
        return resolved
    }

    /// Launches still outstanding at a byte offset. A completion notification
    /// resolves positionally (a turn that ended mid-task stays muted even when
    /// rescanned after the task finished); a launch whose notification is
    /// queued but undelivered stays outstanding unconditionally — the harness
    /// is about to re-invoke the session with the result, so every turn until
    /// the delivery only ended to await it, and a liveness probe (which would
    /// truthfully report the work finished) must not unmute it. A launch with
    /// no notification at all resolves only via the liveness probes above.
    /// Whether a user turn appears after `pos`. Nothing but a user turn can
    /// follow a genuine `end_turn` (the agent only resumes when re-invoked), so
    /// this is the exact test for "a prompt re-engaged the agent" — the signal
    /// that a settled turn was transient and must not be narrated.
    static func userTurnLanded(after pos: Int, in turns: [Turn]) -> Bool {
        turns.contains { $0.role == "user" && $0.pos > pos }
    }

    static func outstandingCount(_ launches: [BackgroundLaunch], before pos: Int,
                                 resolved: Set<String>) -> Int {
        launches.filter { launch in
            guard launch.pos < pos else { return false }
            if let done = launch.donePos { return done >= pos }
            if launch.queuedPos != nil { return true }
            return !resolved.contains(launch.id)
        }.count
    }

    /// Whether any process holds `path` open. Probe failure reports "held" so a
    /// broken lsof degrades to the old always-mute behavior, never a false speak.
    static func isFileHeldOpen(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-t", "--", path]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        guard (try? p.run()) != nil else { return true }
        p.waitUntilExit()
        return p.terminationStatus == 0   // lsof exits 1 when no process has it open
    }

    /// Whether any process was spawned by this session and still runs — every
    /// shell the CLI spawns (foreground, background task, or monitor) carries
    /// `export CLAUDE_SESSION_ID=<sid>` in its argv. pgrep failure reports
    /// "alive" so the probe degrades to muting, never a false speak.
    static func sessionHasLiveShells(sid: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "CLAUDE_SESSION_ID=\(sid)"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        guard (try? p.run()) != nil else { return true }
        p.waitUntilExit()
        return p.terminationStatus == 0   // pgrep exits 1 when nothing matches
    }

    /// A finished agent's subagent transcript ends with an assistant event whose
    /// stop_reason is "end_turn"; while it works, the tail is tool_use or a
    /// pending tool_result. Only the last ~8 KB is read. Unreadable or marker-less
    /// tails report "running" (mute) — a missing file reports finished (reaped).
    static func agentFinished(subagentTranscript path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return true }
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 8192 ? size - 8192 : 0)
        guard let data = try? handle.readToEnd() else { return false }
        for lineData in data.split(separator: 0x0A).reversed() {
            guard let event = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                  event["type"] as? String == "assistant",
                  let message = event["message"] as? [String: Any] else { continue }
            return message["stop_reason"] as? String == "end_turn"
        }
        return false
    }

    /// `…/projects/<proj>/<sid>.jsonl` → `…/projects/<proj>/<sid>/subagents/agent-<id>.jsonl`
    static func subagentTranscriptPath(transcriptPath: String, sid: String, agentID: String) -> String {
        let dir = (transcriptPath as NSString).deletingLastPathComponent
        return "\(dir)/\(sid)/subagents/agent-\(agentID).jsonl"
    }

    /// `…/projects/<proj>/<sid>.jsonl` → `…/projects/<proj>/<sid>/workflows/<runId>.json`
    /// — written (with status and full result) only when the run ends.
    static func workflowStateFilePath(transcriptPath: String, sid: String, runID: String) -> String {
        let dir = (transcriptPath as NSString).deletingLastPathComponent
        return "\(dir)/\(sid)/workflows/\(runID).json"
    }

    // MARK: - Filesystem

    private static func transcriptPaths() -> [String] {
        let projects = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: projects) else { return [] }
        var paths: [String] = []
        for dir in dirs {
            let full = (projects as NSString).appendingPathComponent(dir)
            guard let files = try? fm.contentsOfDirectory(atPath: full) else { continue }
            for f in files where f.hasSuffix(".jsonl") {
                paths.append((full as NSString).appendingPathComponent(f))
            }
        }
        return paths
    }

    private static func fileSize(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
    }
}
