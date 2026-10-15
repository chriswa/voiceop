import Foundation

/// Maps the player's source-sample clock onto narration, excluding silent
/// network gaps. A seek starts a new scheduling generation: callbacks emitted
/// by AVAudioPlayerNode.stop() must never acknowledge the replacement audio.
struct PlaybackTimeline {
    struct Span {
        let sourceStart: Int64
        let nodeStart: Int64
        let count: Int64
    }
    private(set) var spans: [Span] = []
    private(set) var generation = 0
    private(set) var origin: Int64 = 0
    private(set) var acknowledged: Int64 = 0
    var nodeEnd: Int64 { spans.last.map { $0.nodeStart + $0.count } ?? 0 }

    mutating func reset(at frame: Int64) {
        generation += 1
        spans.removeAll(keepingCapacity: true)
        origin = frame
        acknowledged = frame
    }

    mutating func schedule(sourceStart: Int64, count: Int64, nodeStart: Int64) {
        spans.append(Span(sourceStart: sourceStart, nodeStart: nodeStart, count: count))
    }

    func position(nodeFrame: Int64) -> Int64 {
        // Binary search matters when a long streamed read has thousands of
        // packets and the visual reader samples this at 60 Hz.
        var lo = 0, hi = spans.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if spans[mid].nodeStart <= nodeFrame { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return origin }
        let span = spans[lo - 1]
        return span.sourceStart + min(span.count, max(0, nodeFrame - span.nodeStart))
    }

    @discardableResult
    mutating func acknowledge(end: Int64, generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        acknowledged = max(acknowledged, end)
        return true
    }
}

/// When the player node has been playing, by the monotonic clock
/// (`ProcessInfo.systemUptime`), since its clock last started from zero: so
/// that a moment in the past can be turned back into the node frame it was
/// playing then. The node's own clock stands still while it is paused between
/// sentences, so wall-clock time alone would count those pauses as speech.
struct PlayingClock {
    private struct Run { let start: TimeInterval; var end: TimeInterval? }
    private var runs: [Run] = []
    /// Runs that ended longer ago than this are dropped: nothing looks back further.
    static let horizon: TimeInterval = 30

    mutating func started(at now: TimeInterval) {
        guard runs.last.map({ $0.end != nil }) ?? true else { return }
        runs.removeAll { ($0.end ?? now) < now - Self.horizon }
        runs.append(Run(start: now))
    }

    mutating func paused(at now: TimeInterval) {
        guard let last = runs.indices.last, runs[last].end == nil else { return }
        runs[last].end = now
    }

    /// The node's clock went back to zero (`AVAudioPlayerNode.stop()`): nothing before now can be looked back at.
    mutating func reset() { runs.removeAll() }

    /// How long the node has been playing between `since` and `now`.
    func playingSeconds(since: TimeInterval, now: TimeInterval) -> TimeInterval {
        runs.reduce(0) { total, run in
            total + max(0, min(run.end ?? now, now) - max(run.start, since))
        }
    }
}

/// Session lifecycle uses a monotonic clock. The caller supplies the saved rate
/// when starting a session and persists adjustments separately.
struct PlaybackControls {
    private(set) var rate: Float = 1
    private(set) var completed = false
    private(set) var replaying = false
    private var expiresAt: TimeInterval?

    init(rate: Float = 1) { self.rate = PlaybackPreferences.validRate(rate) }

    mutating func adjust(by delta: Float) {
        rate = min(5, max(0.5, (10 * (rate + delta)).rounded() / 10))
    }
    mutating func finish(now: TimeInterval) {
        completed = true
        replaying = false
        expiresAt = now + 2
    }
    func canRewind(now: TimeInterval) -> Bool {
        !completed || replaying || expiresAt.map { now < $0 } == true
    }
    mutating func rewind(now: TimeInterval) -> Bool {
        guard canRewind(now: now) else { return false }
        replaying = completed
        expiresAt = nil
        return true
    }
}
