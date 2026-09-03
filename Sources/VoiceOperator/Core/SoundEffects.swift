import AVFoundation

/// Every audible cue, synthesized in-process as short chirps (no bundled assets).
/// Distinct shapes so they're recognizable without looking (e.g. rising vs.
/// falling two-tone for capture start/stop, a low descending pair for muting).
///
/// This enum is the single source of truth for the cues: each case declares its
/// own `segments` (the notes it plays), `volume`, and `menuLabel` via exhaustive
/// switches, so the compiler forces every case to be fully defined. `SoundBank`
/// builds a WAV for *every* `allCases` entry, and the debug "Play Tone" menu lists
/// `allCases` too — so a cue can never be referenced without also being audible
/// and testable from that menu.
///
/// Capture/mute cues must play *outside* the dictation output-mute window (see
/// AudioArbiter), otherwise the system-output mute would swallow them.
enum SoundEffect: CaseIterable {
    case listeningStarted           // Fn (paste) capture began
    case listeningFinished          // Fn (paste) capture ended
    case commandListeningStarted    // Ctrl+Fn (command) capture began
    case commandListeningFinished   // Ctrl+Fn (command) capture ended
    case listeningFinishedSlow          // Fn capture ended, but the live stream is down: slow path
    case commandListeningFinishedSlow   // Ctrl+Fn capture ended, slow path
    case pasted
    case silenceSkipped             // recording had no speech — transcription skipped
    case surfaceRaised              // a voice tool matched + ran
    case unrecognized               // command matched no tool ("sad")
    case transcriptionFailed        // transcription request errored
    case transcriptionPending       // transcription is still in progress
    case summarizing                // started waiting on Claude/Haiku (very short)
    case clipRequested              // started fetching a TTS clip (very short)
    case clipStarted                // TTS playback began (very short)
    case clipFinished               // TTS playback finished (very short)
    case narrationMuted             // narration muted — low descending slide
    case narrationUnmuted           // narration unmuted — low ascending slide
    case restarting                 // the app is about to relaunch itself

    /// Global playback-speed multiplier for every cue. This lives with the
    /// cue definitions, rather than on the main-actor SoundBank, because the
    /// recorder needs a cue duration from its audio callback to exclude the
    /// start chirp from metering.
    static let speedup = 2.0

    @MainActor func play() { SoundBank.shared.play(self) }
    @MainActor func stop() { SoundBank.shared.stop(self) }

    /// The tone's note segments: `(frequency Hz, duration seconds)`; a frequency
    /// of 0 is silence. Written at natural (1×) durations — `SoundBank.speedup`
    /// scales the whole set. Exhaustive by design: adding a case forces a sound.
    var segments: [(freq: Double, dur: Double)] {
        switch self {
        // Paste mode: low-ish rising/falling two-tone.
        case .listeningStarted:  return [(660, 0.09), (990, 0.11)]
        case .listeningFinished: return [(990, 0.09), (660, 0.11)]
        // Command mode: brighter, higher-pitched rising/falling — clearly
        // distinct from paste so you can hear which mode you're in.
        case .commandListeningStarted:  return [(988, 0.08), (1319, 0.11)]
        case .commandListeningFinished: return [(1319, 0.08), (988, 0.11)]
        // Slow-path variants: the same finish two-tone, then a beat of silence
        // and one low held note. The mode stays audible in the first half; the
        // tail says "this one is going the long way round" (see StreamHealth).
        case .listeningFinishedSlow:        return [(990, 0.09), (660, 0.11), (0, 0.05), (330, 0.24)]
        case .commandListeningFinishedSlow: return [(1319, 0.08), (988, 0.11), (0, 0.05), (494, 0.24)]
        // Cheerful rising major arpeggio (C5–E5–G5–C6) — text inserted.
        case .pasted: return [(523, 0.09), (659, 0.09), (784, 0.09), (1047, 0.14)]
        // Gentle low descending two-tone (G4→C4) — recording was silent, so
        // transcription was skipped. A soft "deflating" cue, distinct from
        // the command "unrecognized" and the harsher error tone.
        case .silenceSkipped: return [(392, 0.12), (262, 0.22)]
        // Rising three-tone "swoop" — a voice tool matched + ran.
        case .surfaceRaised: return [(700, 0.06), (950, 0.06), (1300, 0.11)]
        // Descending low two-tone — "sad": command matched no tool.
        case .unrecognized: return [(415, 0.13), (311, 0.22)]
        // Descending minor three-tone — something went wrong (e.g. the
        // transcription request failed). Longer/lower than "unrecognized"
        // so an error is audibly distinct from a mere no-match.
        case .transcriptionFailed: return [(523, 0.10), (392, 0.10), (262, 0.22)]
        // One plain tone repeated five times, with short gaps. The individual
        // repetitions decay through `segmentVolumes` below rather than changing
        // pitch, creating the requested echo without sounding melodic.
        // This adds up to three natural seconds, or 1.5 seconds at `speedup`.
        case .transcriptionPending: return [(660, 0.48), (0, 0.12), (660, 0.48), (0, 0.12), (660, 0.48), (0, 0.12), (660, 0.48), (0, 0.12), (660, 0.48), (0, 0.12)]
        // Soft ascending double-blip — Claude/Haiku summarization began.
        // Distinct from the single-blip clip cues so a "waiting on Claude"
        // beat is audibly its own state before any TTS fetch.
        case .summarizing: return [(784, 0.04), (1046, 0.05)]
        // Very short single blips around each TTS clip's lifecycle.
        case .clipRequested: return [(1200, 0.04)]
        case .clipStarted:   return [(1600, 0.04)]
        case .clipFinished:  return [(900, 0.05)]
        // Mute/unmute: a quick low descending/ascending three-note slide, well
        // below every other cue's register so muting the app is unmistakable.
        // Mute drops low→lower (A3→E3→A2); unmute climbs very-low→low (A2→E3→A3).
        case .narrationMuted:   return [(220, 0.05), (165, 0.05), (110, 0.11)]
        case .narrationUnmuted: return [(110, 0.05), (165, 0.05), (220, 0.11)]
        // "Power cycle": a fall through the octave and straight back up
        // (A5→E5→A4→A5). Mid register, four notes, so it is neither the
        // pasted arpeggio nor the low mute slides. Plays after the dictation
        // output-mute has been restored (see RestartCoordinator).
        case .restarting: return [(880, 0.08), (659, 0.08), (440, 0.12), (880, 0.16)]
        }
    }

    /// How long the cue actually plays for, once `speedup` is applied.
    /// The dictation start cue now fires *after* the microphone is live (that is
    /// the whole point of it — it means "safe to talk"), so it is picked up by the
    /// mic. `AudioRecorder.excludeFromMetering(seconds:)` uses this to keep the cue
    /// out of the silence-gate measurement.
    var duration: Double { segments.reduce(0) { $0 + $1.dur } / Self.speedup }

    /// Relative amplitude per segment. All normal cues use a uniform level;
    /// the pending transcription cue decays each repetition like an echo.
    var segmentVolumes: [Double] {
        switch self {
        case .transcriptionPending: return [1.0, 0, 0.50, 0, 0.25, 0, 0.12, 0, 0.06, 0]
        default: return Array(repeating: 1.0, count: segments.count)
        }
    }

    /// Per-cue synthesis volume (0–1), applied on top of `SoundBank`'s output
    /// gain. Most cues play at full scale; the very short "background" blips are
    /// quieter so they don't dominate.
    var volume: Double {
        switch self {
        case .transcriptionPending: return 0.18
        case .summarizing, .clipRequested, .clipStarted, .clipFinished: return 0.5
        default: return 1.0
        }
    }

    /// Human-readable name for the debug "Play Tone" menu.
    var menuLabel: String {
        switch self {
        case .listeningStarted:         return "Listening started (paste)"
        case .listeningFinished:        return "Listening finished (paste)"
        case .commandListeningStarted:  return "Listening started (command)"
        case .commandListeningFinished: return "Listening finished (command)"
        case .listeningFinishedSlow:        return "Listening finished (paste, slow path)"
        case .commandListeningFinishedSlow: return "Listening finished (command, slow path)"
        case .pasted:                   return "Pasted"
        case .silenceSkipped:           return "Silence skipped (no speech)"
        case .surfaceRaised:            return "Surface raised (tool ran)"
        case .unrecognized:             return "Unrecognized (no match)"
        case .transcriptionFailed:      return "Transcription failed"
        case .transcriptionPending:     return "Transcription pending"
        case .summarizing:              return "Summarizing (waiting on Claude)"
        case .clipRequested:            return "Clip requested"
        case .clipStarted:              return "Clip started"
        case .clipFinished:             return "Clip finished"
        case .narrationMuted:           return "Narration muted"
        case .narrationUnmuted:         return "Narration unmuted"
        case .restarting:               return "Restarting"
        }
    }
}

@MainActor
final class SoundBank {
    static let shared = SoundBank()
    private var players: [(effect: SoundEffect, player: AVAudioPlayer)] = [] // keep alive during playback

    private let wavs: [SoundEffect: Data]

    private init() {
        // Build a WAV for *every* effect from its own declared segments, so no
        // case can exist without an audible tone. The definitions live on
        // `SoundEffect` itself (see `segments`/`volume`) — this is just synthesis.
        var wavs: [SoundEffect: Data] = [:]
        for effect in SoundEffect.allCases {
            wavs[effect] = Self.chirp(effect.segments, segmentVolumes: effect.segmentVolumes, volume: effect.volume)
        }
        self.wavs = wavs
    }

    func play(_ effect: SoundEffect) {
        guard let data = wavs[effect], let player = try? AVAudioPlayer(data: data) else { return }
        players.removeAll { !$0.player.isPlaying }
        player.volume = 0.35
        player.prepareToPlay()
        player.play()
        players.append((effect, player))
    }

    /// Stops every active instance of one effect. This is used for the pending
    /// transcription cue so a returned result cuts the current echo off at once.
    func stop(_ effect: SoundEffect) {
        for entry in players where entry.effect == effect {
            entry.player.stop()
        }
        players.removeAll { !$0.player.isPlaying }
    }

    // MARK: - Synthesis

    /// Build a 16-bit mono 44.1 kHz WAV from a sequence of (frequency, seconds)
    /// segments. A frequency of 0 is silence. Each tone gets a short fade to
    /// avoid clicks. Durations are scaled by `speedup`.
    private static func chirp(
        _ segments: [(freq: Double, dur: Double)],
        segmentVolumes: [Double],
        volume: Double = 1.0
    ) -> Data {
        let sampleRate = 44_100.0
        var samples: [Int16] = []
        for (seg, segmentVolume) in zip(segments, segmentVolumes) {
            let n = Int(seg.dur / SoundEffect.speedup * sampleRate)
            let fade = max(1, Int(0.005 * sampleRate))
            for i in 0..<n {
                var env = 1.0
                if i < fade { env = Double(i) / Double(fade) }
                else if i > n - fade { env = Double(n - i) / Double(fade) }
                let value: Double = seg.freq == 0 ? 0
                    : env * sin(2 * .pi * seg.freq * Double(i) / sampleRate)
                samples.append(Int16(max(-1, min(1, value)) * segmentVolume * volume * 32000))
            }
        }
        let bytes = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        return WAVFile(sampleRate: Int(sampleRate), samples: bytes).data
    }
}
