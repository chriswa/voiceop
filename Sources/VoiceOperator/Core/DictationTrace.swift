import Foundation

/// A monotonic timeline for one dictation, from the instant the trigger key goes
/// down to the moment the transcript is pasted.
///
/// Every interesting phase calls `mark(_:)`, which records milliseconds since
/// key-down; `flush()` writes the whole timeline as a single log line. The point
/// is that the two questions we actually care about are answerable from one line:
///
///   • **"why did I lose my first words?"** → the `audio` mark. That is when the
///     first real microphone buffer arrived, i.e. the first instant we could
///     hear anything. Everything before it is deaf time.
///   • **"why was the transcript slow?"** → `commit` vs `result`. Because audio
///     now uploads while you speak (see `FlowSession`), the only latency the
///     user experiences after releasing the key is `result - commit`. If that is
///     small and the total is still large, the problem is upstream of the
///     network, and the earlier marks say where.
///
/// Marks are taken from threads that have no business synchronising with each
/// other (the CoreAudio tap thread, the gRPC event loop, the main actor), so the
/// storage is lock-guarded and the clock is `DispatchTime` — monotonic, so a
/// clock adjustment mid-dictation cannot produce a negative duration.
final class DictationTrace: @unchecked Sendable {
    private static let counter = Counter()

    private let name: String
    private let origin: UInt64
    private let lock = NSLock()
    private var marks: [(name: String, ms: Double)] = []
    private var notes: [String] = []
    private var flushed = false

    /// Starts the clock. Create this at the *trigger key event*, not when
    /// recording begins — the gap between the two is exactly what we're hunting.
    init(_ label: String = "dictate") {
        name = "\(label)#\(Self.counter.next())"
        origin = DispatchTime.now().uptimeNanoseconds
    }

    /// Milliseconds since key-down.
    var elapsedMS: Double {
        Double(DispatchTime.now().uptimeNanoseconds &- origin) / 1_000_000
    }

    /// Record a phase boundary. Returns its offset so callers can log detail
    /// alongside it without reading the clock twice.
    @discardableResult
    func mark(_ phase: String) -> Double {
        let ms = elapsedMS
        lock.lock(); marks.append((phase, ms)); lock.unlock()
        return ms
    }

    /// Attach a free-form fact to the timeline (packet counts, server timings,
    /// the leading-level profile). Rendered after the marks.
    func note(_ text: String) {
        lock.lock(); notes.append(text); lock.unlock()
    }

    /// Write the timeline out. Safe to call more than once — only the first call
    /// logs, so an early-return path and the normal path can both finish the
    /// trace without producing a duplicate line.
    func flush() {
        lock.lock()
        guard !flushed else { lock.unlock(); return }
        flushed = true
        let marks = self.marks
        let notes = self.notes
        lock.unlock()

        let timeline = marks.map { "\($0.name)=" + String(format: "%.0f", $0.ms) }.joined(separator: " ")
        var line = "trace \(name): \(timeline)"
        if !notes.isEmpty { line += " | " + notes.joined(separator: " | ") }
        Log.log(line)
    }

    /// Monotonic dictation numbering, so interleaved traces in the log can be
    /// told apart (a retry can overlap the dictation that spawned it).
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }
}
