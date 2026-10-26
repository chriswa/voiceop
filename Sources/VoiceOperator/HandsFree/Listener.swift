import Foundation

// Hands-free mode's ears: what the held-open microphone hears, cut into speech
// and not-speech, and two questions asked of it.
//
// Speech is *speech*, not loudness: each 32 ms frame arrives scored by a
// voice-activity model (Silero VAD) with the probability that someone is
// talking in it, so music, a television's hum, a fan or a noisy room are not
// speech, however loud. Without the model, loudness against the room's level
// stands in (`EnergyScorer`).
//
// While waiting for the wake word (`WakeListener`): has the user just started
// talking, with nobody talking just before? Then the first second of it is a
// *candidate* — handed out to be checked for a leading "Control" — and the
// audio from its start stays in an eight-second buffer, so that a dictation
// can be fed everything said from the first syllable, however long the check
// took. Everything else is forgotten as it scrolls out of the buffer; nothing
// is kept, transcribed or sent.
//
// After the wake word (`UtteranceEndpointer`): has the user paused — a pause
// the record keeps, with what the turn model made of it — and has the pause
// gone on long enough to end it regardless?
//
// Pure: scored frames in, events out, time measured in samples. No clock, no
// microphone, no model — so every threshold is testable with synthetic frames.
// All audio here is 16 kHz signed 16-bit mono.
//
// Ported from Spaceterm's `src/mobile/wake-listener.ts`; same thresholds and
// semantics.

/// Every threshold hands-free listening uses, in milliseconds. `standard` is
/// the only set; there is no tuning file.
struct HandsFreeTuning: Sendable, Equatable {
    var noSpeechBeforeMs: Double
    var onsetWindowMs: Double
    var wordMinMs: Double
    var pauseCheckMs: Double
    var wakeWordOnlyMs: Double
    var afterWakeWordMs: Double
    var endSilenceMinMs: Double
    var endSilenceMaxMs: Double
    var endSilenceRampMs: Double
    var maxUtteranceMs: Double
    var playbackTailMs: Double
    var conversationMs: Double

    static let standard = HandsFreeTuning(
        noSpeechBeforeMs: 700,
        onsetWindowMs: 1000,
        wordMinMs: 250,
        // A pause is reported, and its line in the record begun, once the quiet has lasted this long.
        pauseCheckMs: 500,
        wakeWordOnlyMs: 1500,
        // Capped at 4 s, like the silence timeout below (October 25): five felt endless.
        afterWakeWordMs: 4000,
        endSilenceMinMs: 3000,
        // Spaceterm let a monologue's patience grow to 20 s; waited out, even 5 s was
        // too long (October 25). It grows from 3 s to 4 s at most.
        endSilenceMaxMs: 4000,
        endSilenceRampMs: 300_000,
        maxUtteranceMs: 600_000,
        playbackTailMs: 400,
        conversationMs: 15_000
    )
}

/// The audio format hands-free listens in, and sample/millisecond conversion.
enum HandsFreeAudio {
    static let sampleRate = 16_000
    /// One analysis frame: 32 ms, what Silero VAD takes at 16 kHz.
    static let frameSamples = 512
    static let frameMs: Double = ms(samples: frameSamples)

    static func ms(samples: Int) -> Double {
        Double(samples) / Double(sampleRate) * 1000
    }

    static func samples(ms: Double) -> Int {
        Int(jsRound(ms / 1000 * Double(sampleRate)))
    }
}

/// JavaScript's `Math.round` (halves toward +∞), so rounded timings and levels
/// match the original exactly, negative dB included.
private func jsRound(_ x: Double) -> Double {
    (x + 0.5).rounded(.down)
}

/// The frame's loudness, RMS in dBFS.
func levelDb(_ frame: [Int16]) -> Double {
    var sum = 0.0
    for s in frame { sum += Double(s) * Double(s) }
    let rms = (sum / Double(max(1, frame.count))).squareRoot() / 32768
    return rms > 0 ? 20 * log10(rms) : -120
}

/// Scores one frame with the probability that someone is speaking in it.
protocol FrameScorer: AnyObject {
    var name: String { get }
    func score(_ frame: [Int16]) throws -> Float
    func reset()
}

/// A frame of audio, and the probability that someone is speaking in it.
struct ScoredFrame: Sendable {
    let pcm: [Int16]
    let p: Float
}

/// Speech starting and stopping, from frame probabilities, with Silero's own
/// hysteresis: it starts at `start` held for `startFrames` frames (a click is
/// one), and stops after `hangoverFrames` below `stop` — the closure inside a
/// word like "con-trol" must not split it.
final class SpeechGate {
    static let start: Float = 0.5
    static let stop: Float = 0.35
    static let startFrames = 2
    static let hangoverFrames = 5

    enum Change { case start, stop }

    private var run = 0
    private var quiet = 0
    private(set) var speaking = false

    /// `.start` when speech began (`startFrames` ago), `.stop` when it ended
    /// (`hangoverFrames` ago), otherwise nil.
    func push(_ p: Float) -> Change? {
        if !speaking {
            run = p >= Self.start ? run + 1 : 0
            if run >= Self.startFrames {
                speaking = true
                quiet = 0
                return .start
            }
            return nil
        }
        quiet = p < Self.stop ? quiet + 1 : 0
        if quiet >= Self.hangoverFrames {
            speaking = false
            run = 0
            return .stop
        }
        return nil
    }

    func reset() {
        speaking = false
        run = 0
        quiet = 0
    }
}

/// Speech by loudness, for when the voice-activity model is unavailable:
/// louder than the room by a margin. The room's level falls at once to anything
/// quieter and creeps back up slowly, so a fan raises it but a voice does not.
/// Music and chatter, unlike the model, it hears as speech.
final class EnergyScorer: FrameScorer {
    static let marginDb = 12.0
    static let absoluteMinDb = -58.0
    /// Per frame: about 2.5 dB/s.
    static let floorRiseDb = 0.08
    let name = "loudness"
    private var floorDb = -70.0

    func score(_ frame: [Int16]) -> Float {
        let db = levelDb(frame)
        let loud = db > floorDb + Self.marginDb && db > Self.absoluteMinDb
        if db < floorDb {
            floorDb = max(-100, db)
        } else if !loud {
            floorDb += Self.floorRiseDb
        }
        return loud ? 0.9 : 0.05
    }

    func reset() { /* the room's level is the room's */ }
}

/// Splits arbitrary blocks into whole frames.
final class Framer {
    private var pending: [Int16] = []

    func frames(_ block: [Int16]) -> [[Int16]] {
        let all = pending + block
        let n = HandsFreeAudio.frameSamples
        var out: [[Int16]] = []
        var offset = 0
        while offset + n <= all.count {
            out.append(Array(all[offset..<offset + n]))
            offset += n
        }
        pending = Array(all[offset...])
        return out
    }

    func reset() { pending = [] }
}

/// The last few seconds of audio, by absolute sample number.
private final class Recent {
    private var buffer: [Int16]
    /// Absolute sample number one past the newest sample held.
    private var end = 0

    init(seconds: Int) {
        buffer = [Int16](repeating: 0, count: seconds * HandsFreeAudio.sampleRate)
    }

    func push(_ frame: [Int16]) {
        let size = buffer.count
        for (i, s) in frame.enumerated() { buffer[(end + i) % size] = s }
        end += frame.count
    }

    /// Samples [from, to), clamped to what is still held.
    func slice(from: Int, to: Int) -> [Int16] {
        let start = max(from, end - buffer.count, 0)
        let stop = min(to, end)
        let count = max(0, stop - start)
        var out = [Int16](repeating: 0, count: count)
        for i in 0..<count { out[i] = buffer[(start + i) % buffer.count] }
        return out
    }

    func clear() {
        for i in buffer.indices { buffer[i] = 0 }
    }
}

/// Speech began with nobody speaking before it, and here is its start — the
/// first `onsetWindowMs`, or all of it if it stopped sooner. `start` is the
/// sample it began at, for `WakeListener.audioSince`.
struct WakeCandidate: Sendable {
    let id: Int
    let clip: [Int16]
    let start: Int
    let noSpeechBeforeMs: Int
    /// How long it had been speech when handed out: the whole burst if it
    /// stopped, else the window.
    let spokeMs: Int
}

/// Every burst of speech the listener noticed, and what it made of it — for
/// the record, so a wake word that never triggered can be explained. Timings
/// and levels only; nothing of what was said.
struct SpeechSighting: Sendable, Equatable {
    /// `checked`: its start was handed out. `afterSpeech`: someone was talking
    /// too recently. `tooShort`: a click or a cough.
    enum Verdict: String, Sendable {
        case checked
        case afterSpeech = "after-speech"
        case tooShort = "too-short"
    }

    let verdict: Verdict
    let durationMs: Int
    let noSpeechBeforeMs: Int
    /// Its loudest frame, dBFS.
    let peakDb: Int
}

/// Audio kept before the speech began, so its soft first consonant reaches the
/// check and the transcriber.
let handsFreeLeadMs: Double = 200

/// Listening for the wake word: see the comment at the top of this file.
final class WakeListener {
    /// Speech under way: where it began, what came before, how loud, and
    /// whether its start was handed out.
    private struct Speech {
        let start: Int
        let noSpeechBefore: Int
        var peakDb: Double
        let eligible: Bool
        var handedOut: Bool
    }

    var tuning: HandsFreeTuning
    private let onSpeech: (SpeechSighting) -> Void
    private let gate = SpeechGate()
    private let recent = Recent(seconds: 8)
    /// Absolute sample number of the next frame.
    private(set) var position = 0
    /// Where the last speech ended (or listening resumed): "no speech before"
    /// is measured from here.
    private var quietFrom = 0
    private var speech: Speech?
    private var nextId = 1
    /// The conversation window is open: speech counts however soon it follows
    /// other speech.
    private var conversation = false

    init(tuning: HandsFreeTuning = .standard, onSpeech: @escaping (SpeechSighting) -> Void = { _ in }) {
        self.tuning = tuning
        self.onSpeech = onSpeech
    }

    /// In the conversation window any words will do, so "nobody talking just
    /// before" — there to keep a "control" mid-sentence from counting — no
    /// longer applies: speech straight after a cough, a rejected start, or what
    /// echo cancellation let through of Control's voice is checked like any
    /// other.
    func setConversation(_ open: Bool) { conversation = open }

    /// Whether someone is speaking now, as far as it has heard.
    var speaking: Bool { gate.speaking }

    /// Speech under way that will be checked but has not yet been handed out:
    /// still short of `onsetWindowMs`, and perhaps a cough. Speech too soon
    /// after other speech, which is never checked, is not undecided.
    var undecided: Bool {
        guard let speech else { return false }
        return speech.eligible && !speech.handedOut
    }

    /// Start over, as if everything before now were speech: a candidate needs a
    /// full `noSpeechBeforeMs` from here. For after Control's voice or a cue,
    /// which the microphone heard too.
    func resume() {
        gate.reset()
        recent.clear()
        speech = nil
        quietFrom = position
    }

    /// How long ago, in audio heard, sample `from` was: a candidate's `start`
    /// gives how long its speech has gone on.
    func msSince(_ from: Int) -> Double {
        HandsFreeAudio.ms(samples: position - from)
    }

    /// Everything heard from sample `from` (with `handsFreeLeadMs` before it)
    /// up to now, as far back as the buffer goes.
    func audioSince(_ from: Int) -> [Int16] {
        recent.slice(from: from - HandsFreeAudio.samples(ms: handsFreeLeadMs), to: position)
    }

    func push(_ frames: [ScoredFrame]) -> [WakeCandidate] {
        var candidates: [WakeCandidate] = []
        for frame in frames {
            recent.push(frame.pcm)
            let frameStart = position
            position += frame.pcm.count
            let change = gate.push(frame.p)
            if change == .start {
                // It began startFrames ago; the frames that set it off are speech.
                let start = frameStart - (SpeechGate.startFrames - 1) * HandsFreeAudio.frameSamples
                let noSpeechBefore = start - quietFrom
                speech = Speech(start: start, noSpeechBefore: noSpeechBefore, peakDb: -120,
                                eligible: conversation
                                    || HandsFreeAudio.ms(samples: noSpeechBefore) >= tuning.noSpeechBeforeMs,
                                handedOut: false)
            }
            if speech != nil { speech!.peakDb = max(speech!.peakDb, levelDb(frame.pcm)) }
            if change == .stop, let ended = speech {
                // It ended hangoverFrames ago.
                let end = position - SpeechGate.hangoverFrames * HandsFreeAudio.frameSamples
                quietFrom = end
                speech = nil
                let durationMs = HandsFreeAudio.ms(samples: end - ended.start)
                if !ended.handedOut {
                    // Stopped before its window filled: hand out what there was —
                    // unless it was a click or a cough.
                    let verdict: SpeechSighting.Verdict = !ended.eligible ? .afterSpeech
                        : durationMs < tuning.wordMinMs ? .tooShort : .checked
                    if verdict == .checked { candidates.append(candidate(ended, spokeMs: durationMs)) }
                    onSpeech(sighting(verdict, ended, durationMs: durationMs))
                }
            }
            if let current = speech, current.eligible, !current.handedOut,
               HandsFreeAudio.ms(samples: position - current.start) >= tuning.onsetWindowMs {
                speech!.handedOut = true
                let spokeMs = HandsFreeAudio.ms(samples: position - current.start)
                candidates.append(candidate(current, spokeMs: spokeMs))
                onSpeech(sighting(.checked, current, durationMs: spokeMs))
            }
        }
        return candidates
    }

    private func candidate(_ speech: Speech, spokeMs: Double) -> WakeCandidate {
        defer { nextId += 1 }
        return WakeCandidate(
            id: nextId,
            clip: audioSince(speech.start),
            start: speech.start,
            noSpeechBeforeMs: Int(jsRound(HandsFreeAudio.ms(samples: speech.noSpeechBefore))),
            spokeMs: Int(jsRound(spokeMs))
        )
    }

    private func sighting(_ verdict: SpeechSighting.Verdict, _ speech: Speech, durationMs: Double) -> SpeechSighting {
        SpeechSighting(verdict: verdict,
                       durationMs: Int(jsRound(durationMs)),
                       noSpeechBeforeMs: Int(jsRound(HandsFreeAudio.ms(samples: speech.noSpeechBefore))),
                       peakDb: Int(jsRound(speech.peakDb)))
    }
}

/// How long a pause ends a dictation by itself: `endSilenceMinMs` for a short
/// request, growing linearly with how long the speaker has been going, to
/// `endSilenceMaxMs` at `endSilenceRampMs` — the longer the monologue, the
/// more room for the next thought.
func endSilenceFor(talkMs: Double, tuning: HandsFreeTuning) -> Double {
    let ramp = min(1, talkMs / max(1, tuning.endSilenceRampMs))
    return tuning.endSilenceMinMs + (tuning.endSilenceMaxMs - tuning.endSilenceMinMs) * ramp
}

enum UtteranceEndReason: String, Sendable {
    case silence
    case tooLong = "too-long"
}

enum UtteranceEvent: Equatable, Sendable {
    /// Quiet for `pauseCheckMs`: a pause. Once per pause. `wakeWordOnly`:
    /// nothing has been said yet but the wake word — "Control." and a breath —
    /// which the turn model would hear as finished; its ending waits.
    case pause(talkMs: Int, wakeWordOnly: Bool)
    /// Speech again, after a pause was reported: whatever was made of it no
    /// longer holds.
    case resumed
    /// The quiet outlasted `endSilenceFor`, or the whole thing reached
    /// `maxUtteranceMs`. Once.
    case ended(UtteranceEndReason)
}

/// After the wake word, while the user is talking. It starts mid-speech — the
/// wake word began it — so quiet counts from now, and `alreadyMs` (the time
/// since the speech began, out of the listener's buffer) counts towards the
/// speaker's patience.
///
/// A first pause after less than `wakeWordOnlyMs` of actual speech — counting
/// `alreadySpokeMs` from before it started — is the pause after "Control." on
/// its own: until speech resumes, it waits at least `afterWakeWordMs`, and the
/// turn model does not end it. Speech, not time: the check
/// may have taken a second, which is not the speaker talking. Only when the
/// utterance began with the wake word (`wakeWordStart`): in the conversation
/// window, a short "yes" and a pause is the whole answer.
final class UtteranceEndpointer {
    private let tuning: HandsFreeTuning
    private let alreadyMs: Double
    private let wakeWordStart: Bool
    private let gate = SpeechGate()
    private var at = 0
    private var lastSpeech = 0
    private var pauses = 0
    private var spokeMs: Double
    private var pauseReported = false
    /// Only the wake word has been said: the first pause came this early and
    /// speech has not resumed.
    private var wakeWordOnly = false
    private var done = false

    init(tuning: HandsFreeTuning = .standard, alreadyMs: Double = 0, alreadySpokeMs: Double = 0,
         wakeWordStart: Bool = true) {
        self.tuning = tuning
        self.alreadyMs = alreadyMs
        self.spokeMs = alreadySpokeMs
        self.wakeWordStart = wakeWordStart
    }

    func push(_ frames: [ScoredFrame]) -> [UtteranceEvent] {
        var events: [UtteranceEvent] = []
        if done { return events }
        for frame in frames {
            at += frame.pcm.count
            if gate.speaking { spokeMs += HandsFreeAudio.frameMs }
            if gate.push(frame.p) == .start && pauseReported {
                pauseReported = false
                wakeWordOnly = false
                events.append(.resumed)
            }
            if gate.speaking { lastSpeech = at }
            let talkMs = alreadyMs + HandsFreeAudio.ms(samples: at)
            if talkMs >= tuning.maxUtteranceMs {
                done = true
                events.append(.ended(.tooLong))
                break
            }
            if gate.speaking { continue }
            let quiet = quietSoFar
            if !pauseReported && quiet >= tuning.pauseCheckMs {
                pauseReported = true
                pauses += 1
                wakeWordOnly = wakeWordStart && pauses == 1 && spokeMs < tuning.wakeWordOnlyMs
                events.append(.pause(talkMs: Int(jsRound(talkMs)), wakeWordOnly: wakeWordOnly))
            }
            if quiet >= patienceMs {
                done = true
                events.append(.ended(.silence))
                break
            }
        }
        return events
    }

    /// How far the quiet has got towards ending the dictation by itself, 0...1:
    /// 0 while they speak, 1 when it ends on silence. Held where it was once
    /// ended.
    func silence() -> Double {
        if gate.speaking || at == 0 { return 0 }
        return min(1, quietSoFar / patienceMs)
    }

    /// Quiet since the last speech, counting the gate's hangover: 0 while they
    /// speak (or before anything has been heard). With `patienceMs`, the data
    /// points behind `silence()`, for a client drawing its own gauge.
    var quietMs: Double {
        if gate.speaking || at == 0 { return 0 }
        return quietSoFar
    }

    /// How much quiet ends it: `endSilenceFor`, and after the wake word alone
    /// at least `afterWakeWordMs`.
    var patienceMs: Double {
        let talkMs = alreadyMs + HandsFreeAudio.ms(samples: at)
        let patience = endSilenceFor(talkMs: talkMs, tuning: tuning)
        return wakeWordOnly ? max(tuning.afterWakeWordMs, patience) : patience
    }

    /// Quiet since the last speech, counting the gate's hangover, which was
    /// quiet too.
    private var quietSoFar: Double {
        HandsFreeAudio.ms(samples: at - lastSpeech) + Double(SpeechGate.hangoverFrames) * HandsFreeAudio.frameMs
    }
}
