import AVFoundation

/// The three dictation cues, synthesized in-process as short chirps (no bundled
/// assets). Distinct shapes so they're recognizable without looking:
///   • listeningStarted  — rising two-tone  (capture began)
///   • listeningFinished — falling two-tone (capture ended)
///   • pasted            — quick high double-blip (text inserted)
///
/// These must play *outside* the dictation output-mute window (see AudioArbiter),
/// otherwise the system-output mute would swallow them.
enum SoundEffect {
    case listeningStarted           // Fn (paste) capture began
    case listeningFinished          // Fn (paste) capture ended
    case commandListeningStarted    // Ctrl+Fn (command) capture began
    case commandListeningFinished   // Ctrl+Fn (command) capture ended
    case pasted
    case surfaceRaised              // a voice tool matched + ran
    case unrecognized               // command matched no tool ("sad")
    case transcriptionFailed        // transcription request errored
    case clipRequested              // started fetching a TTS clip (very short)
    case clipStarted                // TTS playback began (very short)
    case clipFinished               // TTS playback finished (very short)

    @MainActor func play() { SoundBank.shared.play(self) }
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
            .pasted:            Self.chirp([(1320, 0.06), (0, 0.04), (1320, 0.07)]),
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

    /// Build a 16-bit mono 44.1 kHz WAV from a sequence of (frequency, seconds)
    /// segments. A frequency of 0 is silence. Each tone gets a short fade to
    /// avoid clicks.
    private static func chirp(_ segments: [(freq: Double, dur: Double)], volume: Double = 1.0) -> Data {
        let sampleRate = 44_100.0
        var samples: [Int16] = []
        for seg in segments {
            let n = Int(seg.dur * sampleRate)
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
