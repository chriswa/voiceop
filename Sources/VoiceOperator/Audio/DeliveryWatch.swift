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

    /// A buffer of `seconds` of audio arrived at `now`.
    mutating func delivered(_ seconds: TimeInterval, at now: TimeInterval) {
        coveredUntil = max(coveredUntil ?? now, now) + seconds
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
        guard let coveredUntil else { return (now - openedAt, Self.firstBufferAllowance) }
        // A dictation is never cut short for it: the user is talking, and a
        // false alarm costs them the whole dictation.
        let closely = !recording && now < watchCloselyUntil
        return (max(0, now - coveredUntil), closely ? Self.stallAfterSpeech : Self.stallAfter)
    }

    func isStalled(at now: TimeInterval, recording: Bool) -> Bool {
        let (seconds, limit) = silence(at: now, recording: recording)
        return seconds >= limit
    }
}
