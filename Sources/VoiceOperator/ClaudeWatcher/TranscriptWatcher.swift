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
    private var states: [String: SessionState] = [:]
    private var pending: [String: Pending] = [:]

    private let pollInterval: TimeInterval = 0.5
    private let settleSeconds: TimeInterval = 2.5
    private let maxSettleWait: TimeInterval = 20
    private let spokenHistory = 10
    private let idleTTL: TimeInterval = 30 * 60   // release name/voice after 30m idle

    init(registry: NameVoiceRegistry, emit: @escaping @Sendable (Utterance, [Turn]) -> Void) {
        self.registry = registry
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
        if var p = pending[path] {
            if size != p.size { p.size = size; p.changed = now }
            if now.timeIntervalSince(p.changed) >= settleSeconds
                || now.timeIntervalSince(p.first) >= maxSettleWait {
                states[path] = SessionState(size: size, consumed: size)
                pending[path] = nil
            } else {
                pending[path] = p
            }
        } else {
            pending[path] = Pending(size: size, changed: now, first: now)
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
        for (i, turn) in turns.enumerated() {
            guard turn.role == "assistant", turn.pos >= state.consumed,
                  turn.stopReason == "end_turn" else { continue }

            // Suppress turns while background work is still outstanding.
            let outstanding = parsed.bgEvents.filter { $0.pos < turn.pos }.reduce(0) { $0 + $1.delta }
            if outstanding > 0 {
                Log.log("watcher: [\(sid.prefix(8))] skipped a completed turn — \(outstanding) background task(s) still outstanding")
                continue
            }

            // Context = turns since the previous end-of-turn marker.
            var prev = i - 1
            while prev >= 0 && !(turns[prev].role == "assistant" && turns[prev].stopReason == "end_turn") {
                prev -= 1
            }
            let context = Array(turns[(prev + 1)...i])
            let summary = await ClaudeSummarizer.summarize(context: context, spoken: state.spoken)
            Log.log("watcher: [\(sid.prefix(8))] \(voice.name): \(summary.prefix(60))")
            emit(Utterance(name: voice.name, body: summary, voiceID: voice.voiceID, sessionKey: sid), context)
            state.spoken.append(summary)
            if state.spoken.count > spokenHistory { state.spoken.removeFirst(state.spoken.count - spokenHistory) }
        }
        state.consumed = max(state.consumed, parsed.completeBytes)
        states[path] = state
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
