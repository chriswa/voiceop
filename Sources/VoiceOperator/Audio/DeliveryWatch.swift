import Foundation

/// When an open microphone has stopped handing over audio: the stall
/// watchdog's arithmetic (`AudioRecorder.checkDelivery`), kept apart from
/// Core Audio so it can be tested. Times are seconds on one monotonic clock.
///
/// Two things a live device does on the EPOS BTD 800 III (a wireless headset's
/// USB dongle) that are not stalls, both right after our own speech stops,
/// when the capture engine has just been rebuilt and the headset is changing
/// modes:
///
/// - **Its first buffer comes late.** 11 of 152 dictations on a fresh engine
///   waited 0.75–1.6 s for it, and every one of them then captured normally.
///   A warm engine delivers within ~0.1 s (p99 0.106 s over 5,548 dictations).
/// - **It delivers in bursts.** 0.7 s of audio arrived at once, then nothing
///   for longer than the gap between buffers of a steady stream. Silence is
///   counted from when the audio delivered so far runs out, not from when it
///   arrived.
struct DeliveryWatch: Equatable {
    /// How long an open microphone may take to deliver its first buffer.
    static let firstBufferAllowance: TimeInterval = 3
    /// How long the delivered audio may run dry before it counts as a stall.
    static let stallAfter: TimeInterval = 0.75
    /// The tighter limit for a held microphone, with no recording, in the
    /// `speechWatchSeconds` after our own speech ends: see `speechEnded`.
    static let stallAfterSpeech: TimeInterval = 0.4
    static let speechWatchSeconds: TimeInterval = 3

    /// When the microphone was opened.
    private(set) var openedAt: TimeInterval = 0
    /// Until when the audio delivered since opening covers, or nil before the first buffer.
    private(set) var coveredUntil: TimeInterval?
    /// Until when a held microphone is watched closely: see `speechEnded`.
    private var watchCloselyUntil: TimeInterval = 0

    /// The microphone was opened at `now`.
    mutating func opened(at now: TimeInterval) {
        openedAt = now
        coveredUntil = nil
    }

    /// A buffer of `seconds` of audio arrived at `now`. Returns how long the
    /// microphone had been dry when it came, measured as `silence` measures it
    /// (zero for the first buffer since opening, which `firstBufferAllowance`
    /// covers instead).
    @discardableResult
    mutating func delivered(_ seconds: TimeInterval, at now: TimeInterval) -> TimeInterval {
        let dry = coveredUntil.map { max(0, now - $0) } ?? 0
        coveredUntil = max(coveredUntil ?? now, now) + seconds
        return dry
    }

    /// How long the microphone has been dry at `now`, however long it is allowed.
    func dry(at now: TimeInterval) -> TimeInterval {
        coveredUntil.map { max(0, now - $0) } ?? 0
    }

    /// Our own speech stopped playing at `now`. On the EPOS BTD 800 that once
    /// killed a held microphone for good (2026-10-26), so for
    /// `speechWatchSeconds` a held microphone that has delivered is called
    /// stalled sooner, and rebuilt before the user starts their answer.
    mutating func speechEnded(at now: TimeInterval) {
        watchCloselyUntil = now + Self.speechWatchSeconds
    }

    /// How long the microphone has been dry at `now` and the limit it is held
    /// to, given whether a recording is under way.
    func silence(at now: TimeInterval, recording: Bool) -> (seconds: TimeInterval, limit: TimeInterval) {
        guard coveredUntil != nil else { return (now - openedAt, Self.firstBufferAllowance) }
        // A dictation is never cut short for it: the user is talking, and a
        // false alarm costs them the whole dictation.
        let closely = !recording && now < watchCloselyUntil
        return (dry(at: now), closely ? Self.stallAfterSpeech : Self.stallAfter)
    }

    func isStalled(at now: TimeInterval, recording: Bool) -> Bool {
        let (seconds, limit) = silence(at: now, recording: recording)
        return seconds >= limit
    }
}

/// How well one recording's microphone kept up, for its trace line: the
/// longest dry spell, against `DeliveryWatch.stallAfter`, and how much audio
/// is missing between its first and last buffers. Logging only; nothing acts
/// on it. Times are seconds on `DeliveryWatch`'s clock, audio is seconds at
/// the device's own rate.
struct RecordingDelivery: Equatable {
    /// The earliest the recording's audio can have begun: for each buffer, its
    /// arrival less all the audio delivered up to and including it. A burst
    /// (a fresh engine handing over its backlog at once) moves it earlier, so
    /// the span it starts is never shorter than the audio actually delivered.
    private var startedBy: TimeInterval?
    private var lastAt: TimeInterval = 0
    private var delivered: TimeInterval = 0
    private var longestDry: TimeInterval = 0

    /// A buffer of `seconds` arrived at `now`, after the microphone had been
    /// dry for `dry` (`DeliveryWatch.delivered`).
    mutating func buffer(_ seconds: TimeInterval, dry: TimeInterval, at now: TimeInterval) {
        if startedBy != nil { longestDry = max(longestDry, dry) }
        delivered += seconds
        startedBy = min(startedBy ?? .infinity, now - delivered)
        lastAt = now
    }

    struct Summary: Equatable {
        /// Includes the dry spell the recording stopped in.
        var longestDry: TimeInterval
        /// Audio the span from `startedBy` to the last buffer should have held.
        var expected: TimeInterval
        var delivered: TimeInterval
        var shortfallPercent: Double { expected > 0 ? (expected - delivered) / expected * 100 : 0 }
    }

    /// The recording stopped with the microphone dry for `dryAtStop`; nil if no
    /// audio ever arrived.
    func summary(dryAtStop: TimeInterval) -> Summary? {
        guard let startedBy else { return nil }
        return Summary(longestDry: max(longestDry, dryAtStop), expected: lastAt - startedBy, delivered: delivered)
    }
}
