import AVFoundation

/// The three dictation cues, synthesized in-process as short chirps (no bundled
/// assets). Distinct shapes so they're recognizable without looking:
///   • listeningStarted  — rising two-tone  (capture began)
///   • listeningFinished — falling two-tone (capture ended)
///   • pasted            — quick high double-blip (text inserted)
///
/// These must play *outside* the dictation output-mute window (see AudioArbiter),
/// otherwise the system-output mute would swallow them.
enum SoundEffect: CaseIterable {
    case listeningStarted           // Fn (paste) capture began
    case listeningFinished          // Fn (paste) capture ended
    case commandListeningStarted    // Ctrl+Fn (command) capture began
    case commandListeningFinished   // Ctrl+Fn (command) capture ended
    case pasted
    case silenceSkipped             // recording had no speech — transcription skipped
    case surfaceRaised              // a voice tool matched + ran
    case unrecognized               // command matched no tool ("sad")
    case transcriptionFailed        // transcription request errored
    case clipRequested              // started fetching a TTS clip (very short)
    case clipStarted                // TTS playback began (very short)
    case clipFinished               // TTS playback finished (very short)

    @MainActor func play() { SoundBank.shared.play(self) }

    /// Human-readable name for the debug "Play Tone" menu.
    var menuLabel: String {
        switch self {
        case .listeningStarted:         return "Listening started (paste)"
        case .listeningFinished:        return "Listening finished (paste)"
        case .commandListeningStarted:  return "Listening started (command)"
        case .commandListeningFinished: return "Listening finished (command)"
        case .pasted:                   return "Pasted"
        case .silenceSkipped:           return "Silence skipped (no speech)"
        case .surfaceRaised:            return "Surface raised (tool ran)"
        case .unrecognized:             return "Unrecognized (no match)"
        case .transcriptionFailed:      return "Transcription failed"
        case .clipRequested:            return "Clip requested"
        case .clipStarted:              return "Clip started"
        case .clipFinished:             return "Clip finished"
        }
    }
}

@MainActor
final class SoundBank {
    static let shared = SoundBank()
    private var players: [AVAudioPlayer] = []   // keep alive during playback

    private let wavs: [SoundEffect: Data]

    private init() {
        wavs = [
            // Paste mode: low-ish rising/falling two-tone.
            .listeningStarted:  Self.chirp([(660, 0.09), (990, 0.11)]),
            .listeningFinished: Self.chirp([(990, 0.09), (660, 0.11)]),
            // Command mode: brighter, higher-pitched rising/falling — clearly
            // distinct from paste so you can hear which mode you're in.
            .commandListeningStarted:  Self.chirp([(988, 0.08), (1319, 0.11)]),
            .commandListeningFinished: Self.chirp([(1319, 0.08), (988, 0.11)]),
            // Cheerful rising major arpeggio (C5–E5–G5–C6) — text inserted.
            .pasted:            Self.chirp([(523, 0.09), (659, 0.09), (784, 0.09), (1047, 0.14)]),
            // Gentle low descending two-tone (G4→C4) — recording was silent, so
            // transcription was skipped. A soft "deflating" cue, distinct from
            // the command "unrecognized" and the harsher error tone.
            .silenceSkipped:    Self.chirp([(392, 0.12), (262, 0.22)]),
            // Rising three-tone "swoop" — a voice tool matched + ran.
            .surfaceRaised:     Self.chirp([(700, 0.06), (950, 0.06), (1300, 0.11)]),
            // Descending low two-tone — "sad": command matched no tool.
            .unrecognized:      Self.chirp([(415, 0.13), (311, 0.22)]),
            // Descending minor three-tone — something went wrong (e.g. the
            // transcription request failed). Longer/lower than "unrecognized"
            // so an error is audibly distinct from a mere no-match.
            .transcriptionFailed: Self.chirp([(523, 0.10), (392, 0.10), (262, 0.22)]),
            // Very short single blips around each TTS clip's lifecycle.
            .clipRequested:     Self.chirp([(1200, 0.04)], volume: 0.5),
            .clipStarted:       Self.chirp([(1600, 0.04)], volume: 0.5),
            .clipFinished:      Self.chirp([(900, 0.05)], volume: 0.5),
        ]
    }

    func play(_ effect: SoundEffect) {
        guard let data = wavs[effect], let player = try? AVAudioPlayer(data: data) else { return }
        players.removeAll { !$0.isPlaying }
        player.volume = 0.35
        player.prepareToPlay()
        player.play()
        players.append(player)
    }

    // MARK: - Synthesis

    /// Global playback-speed multiplier for every cue: all note durations and
    /// gaps are divided by this, so >1 makes the whole set proportionally
    /// snappier. Segment tables below are written at their natural (1×) values;
    /// bump this single knob to retune overall snappiness.
    private static let speedup = 2.0

    /// Build a 16-bit mono 44.1 kHz WAV from a sequence of (frequency, seconds)
    /// segments. A frequency of 0 is silence. Each tone gets a short fade to
    /// avoid clicks. Durations are scaled by `speedup`.
    private static func chirp(_ segments: [(freq: Double, dur: Double)], volume: Double = 1.0) -> Data {
        let sampleRate = 44_100.0
        var samples: [Int16] = []
        for seg in segments {
            let n = Int(seg.dur / speedup * sampleRate)
            let fade = max(1, Int(0.005 * sampleRate))
            for i in 0..<n {
                var env = 1.0
                if i < fade { env = Double(i) / Double(fade) }
                else if i > n - fade { env = Double(n - i) / Double(fade) }
                let value: Double = seg.freq == 0 ? 0
                    : env * sin(2 * .pi * seg.freq * Double(i) / sampleRate)
                samples.append(Int16(max(-1, min(1, value)) * volume * 32000))
            }
        }
        let bytes = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        return WAVFile(sampleRate: Int(sampleRate), samples: bytes).data
    }
}
