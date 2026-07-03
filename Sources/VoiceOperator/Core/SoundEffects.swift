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
    case listeningStarted
    case listeningFinished
    case pasted
    case surfaceRaised   // directed reply: raised a spaceterm surface

    @MainActor func play() { SoundBank.shared.play(self) }
}

@MainActor
final class SoundBank {
    static let shared = SoundBank()
    private var players: [AVAudioPlayer] = []   // keep alive during playback

    private let wavs: [SoundEffect: Data]

    private init() {
        wavs = [
            .listeningStarted:  Self.chirp([(660, 0.09), (990, 0.11)]),
            .listeningFinished: Self.chirp([(990, 0.09), (660, 0.11)]),
            .pasted:            Self.chirp([(1320, 0.06), (0, 0.04), (1320, 0.07)]),
            // Rising three-tone "swoop" — distinct from paste; signals a raise.
            .surfaceRaised:     Self.chirp([(700, 0.06), (950, 0.06), (1300, 0.11)]),
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
    private static func chirp(_ segments: [(freq: Double, dur: Double)]) -> Data {
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
                samples.append(Int16(max(-1, min(1, value)) * 32000))
            }
        }
        return wav(samples, sampleRate: Int(sampleRate))
    }

    private static func wav(_ samples: [Int16], sampleRate: Int) -> Data {
        let dataBytes = samples.count * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        for s in samples { u16(UInt16(bitPattern: s)) }
        return d
    }
}
