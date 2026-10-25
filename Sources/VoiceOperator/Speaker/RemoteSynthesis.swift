import Foundation

/// Speech made here and played somewhere else: `/v1/synthesize`, and every
/// sentence `DeviceSpeech` sends a device.
///
/// The text goes through `TTSPreprocess` first, as speech played here does, so
/// a path or a camelCase name sounds the same on a phone. So does
/// `SpeechLoudness`: the device plays the audio as it is, so the gain and
/// limiter speech gets here are applied before it leaves.
enum RemoteSynthesis {
    /// One word of the clip: when it sounds (seconds), and `characterEnd`, the
    /// UTF-16 offset in the text as sent just past it — a spoken "slash" ends
    /// just past the `/` it stands for.
    struct Word: Sendable, Equatable {
        let start: Double
        let end: Double
        let characterEnd: Int
    }

    struct Clip: Sendable {
        let wav: WAVFile
        /// Nil when the timings were not asked for, or could not be had or aligned.
        let words: [Word]?
    }

    static func make(text: String, voice: String, timed: Bool) async throws -> Clip {
        let synthesizer = KokoroSynthesizer()
        let prepared = TTSPreprocess.prepare(text)
        guard timed else {
            return Clip(wav: loud(try WAVFile.parse(await synthesizer.synthesizeWAV(text: prepared.ttsText, voiceID: voice))), words: nil)
        }
        async let timings = try? synthesizer.wordTimings(text: prepared.ttsText, voiceID: voice)
        let wav = loud(try WAVFile.parse(await synthesizer.synthesizeWAV(text: prepared.ttsText, voiceID: voice)))
        return Clip(wav: wav, words: await timings.flatMap { words(prepared: prepared, timings: $0) })
    }

    /// Kokoro times the prepared text; each word is mapped back to where it ends in the text as sent.
    static func words(prepared: TTSPrepared, timings: [WordTiming]) -> [Word]? {
        SpokenNarration.wordRanges(prepared: prepared, words: timings)?.map {
            Word(start: $0.timing.start, end: $0.timing.end, characterEnd: NSMaxRange($0.range))
        }
    }

    /// `SpeechLoudness.boosted` for a synthesized WAV blob. A clip that will not
    /// boost is sent at its original level rather than not at all.
    private static func loud(_ wav: WAVFile) -> WAVFile {
        do { return try SpeechLoudness.boosted(wav) }
        catch { Log.log("remote synthesis: loudness skipped: \(error)"); return wav }
    }
}
