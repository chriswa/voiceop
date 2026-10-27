import AVFoundation
import Foundation

/// The echo experiment's recording kit, for testing it offline rather than
/// only in the room. Not part of the menu-bar app: CLI flags (`main.swift`).
///
/// - `--echo-capture [dir]` plays a fixed set of Control-like replies through
///   the real speech path (`TTSEngine`, on whatever output is the default)
///   while recording the microphone exactly as hands-free hears it
///   (`AudioRecorder.setListener`, 16 kHz). It writes `mic.wav`, the
///   reference that was played lined up with it sample for sample
///   (`reference.wav`, from `EchoReference`, by host time), the microphone
///   through the echo canceller as the experiment would hear it (`aec.wav`),
///   and `capture.json`: the output device, its route, where each reply
///   starts and ends, and how loud the microphone and the canceller's output
///   were during each. Run it once per setup: built-in speakers at a few
///   volumes, AirPods and the headset as controls.
/// - `--echo-capture phrases [dir]` records you saying the cut-in phrases,
///   three seconds each, in the same room on the same microphone, to lay over
///   the echo offline: echo and a voice add up in the air, so the mix is what
///   the microphone would have heard.
/// - `--echo-replay <dir>` runs a capture through the speech detector (raw and
///   cancelled), lays each recorded phrase over each reply at a few offsets,
///   and asks Apple's on-device model what it hears in each mix, as the
///   trigger-word check would. Prints a table; writes the mixes to `mixes/`.
///
/// Captures go to `~/Library/Application Support/VoiceOperator/echo-captures/`
/// unless a directory is given. Recording the microphone to disk is refused
/// in incognito (`save`).
enum EchoCapture {
    static let incognitoActivity = Incognito.Activity.persist("echo captures")

    /// Control-like replies, short to long. One says "Control", as a reply can.
    static let replies = [
        "First question: do you want me to merge it now, or wait for the tests?",
        "Done. Three files changed, and the build is green.",
        "Kevin is still working on the login page. He has two failing tests and is looking at the first one.",
        "Nothing urgent.",
        "Here is the plan. First, I will read the hands-free service and the engine. Then I will add the route to the setup message, and finally the badge on the button. That should take about an hour, and I will tell you when each part is done.",
        "Control is waiting for you to choose between the two designs.",
    ]

    /// What you say to cut in, recorded by `phrases`.
    static let phrases = [
        "Control, stop.",
        "Control, wait.",
        "Control, what's Kevin doing?",
        "Control, hang on a second.",
        "Wait.",
        "Stop.",
    ]

    static var defaultRoot: URL { HistoryStore.supportDir.appendingPathComponent("echo-captures") }

    /// The only way anything here reaches the disk.
    static func save(_ data: Data, to url: URL) throws {
        try Incognito.check(incognitoActivity)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    static func save(_ samples: [Int16], to url: URL) throws {
        try save(WAVFile(sampleRate: HandsFreeAudio.sampleRate, samples: HandsFreeService.data(samples)).data, to: url)
    }

    private static func note(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f.string(from: Date())
    }

    /// The microphone as hands-free hears it, with the host time of the first
    /// sample, from the recorder's tap thread.
    private final class Tape: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Int16] = []
        private var first: UInt64?
        private var nextSeconds = 0.0
        private(set) var gaps = 0

        func append(_ data: Data, hostTime: UInt64) {
            let pcm = HandsFreeService.samples(data)
            lock.withLock {
                let seconds = AVAudioTime.seconds(forHostTime: hostTime)
                if first == nil {
                    first = hostTime
                    nextSeconds = seconds
                } else if abs(seconds - nextSeconds) > MacEchoPath.gapSeconds {
                    gaps += 1
                }
                samples += pcm
                nextSeconds += Double(pcm.count) / EchoReference.sampleRate
            }
        }

        var count: Int { lock.withLock { samples.count } }
        var snapshot: (samples: [Int16], first: UInt64?) { lock.withLock { (samples, first) } }
    }

    // MARK: - Recording the echo

    @MainActor
    static func capture(into dir: URL?) async {
        if let refusal = Incognito.refusal(incognitoActivity) { note("echo-capture: \(refusal)"); exit(1) }
        let out = dir ?? defaultRoot.appendingPathComponent(stamp())
        let route = OutputDevice.route
        note("echo-capture: playing \(replies.count) replies on \(OutputDevice.formatSummary) (route: \(route.rawValue)), "
             + "recording the microphone — into \(out.path)")
        note("echo-capture: keep the room quiet, and do not talk.")
        EchoReference.shared.capturing = true
        EchoReference.shared.clear()
        let recorder = AudioRecorder()
        let tape = Tape()
        recorder.setListener { data, hostTime in tape.append(data, hostTime: hostTime) }
        try? await Task.sleep(for: .seconds(2))
        var takes: [[String: Any]] = []
        let engine = TTSEngine()
        for (i, text) in replies.enumerated() {
            let start = tape.count
            note("  \(i + 1)/\(replies.count): \(text)")
            let ok = await engine.play(Utterance(text: text, voiceID: KokoroSynthesizer.defaultVoiceID), onStart: {})
            try? await Task.sleep(for: .seconds(1.5))
            takes.append(["text": text, "startSample": start, "endSample": tape.count, "played": ok])
        }
        recorder.setListener(nil)
        EchoReference.shared.capturing = false
        let (mic, first) = tape.snapshot
        guard let first, !mic.isEmpty else { note("echo-capture: the microphone delivered nothing"); exit(1) }
        let reference = EchoCanceller.int16(EchoReference.shared.samples(from: first, count: mic.count))
        let early = AVAudioTime.hostTime(forSeconds: AVAudioTime.seconds(forHostTime: first) - EchoCanceller.leadSeconds)
        let aec = cancel(mic, reference: EchoCanceller.int16(EchoReference.shared.samples(from: early, count: mic.count)))
        for (i, take) in takes.enumerated() {
            let range = (take["startSample"] as! Int)..<min(take["endSample"] as! Int, mic.count, aec.count)
            var t = take
            t["micDb"] = rounded(rmsDb(mic[range]))
            t["referenceDb"] = rounded(rmsDb(reference[range]))
            t["aecDb"] = rounded(rmsDb(aec[range]))
            takes[i] = t
        }
        let summary: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()), "output": OutputDevice.formatSummary,
            "route": route.rawValue, "sampleRate": HandsFreeAudio.sampleRate, "gaps": tape.gaps,
            "leadSeconds": EchoCanceller.leadSeconds, "tailSamples": EchoCanceller.tailSamples,
            "silenceDb": rounded(rmsDb(mic[0..<min(mic.count, (takes.first?["startSample"] as? Int) ?? 0)])),
            "takes": takes,
        ]
        do {
            try save(mic, to: out.appendingPathComponent("mic.wav"))
            try save(reference, to: out.appendingPathComponent("reference.wav"))
            try save(aec, to: out.appendingPathComponent("aec.wav"))
            try save(JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]),
                     to: out.appendingPathComponent("capture.json"))
        } catch {
            note("echo-capture: could not save: \(error)"); exit(1)
        }
        note("echo-capture: room \(summary["silenceDb"] ?? 0) dB; gaps in the microphone: \(tape.gaps)")
        for take in takes {
            note("  mic \(take["micDb"] ?? 0) dB → cancelled \(take["aecDb"] ?? 0) dB  (played \(take["referenceDb"] ?? 0) dB)  "
                 + "\(Log.clip(take["text"] as? String ?? ""))")
        }
        note("echo-capture: saved to \(out.path)")
    }

    // MARK: - Recording the phrases

    @MainActor
    static func capturePhrases(into dir: URL?) async {
        if let refusal = Incognito.refusal(incognitoActivity) { note("echo-capture: \(refusal)"); exit(1) }
        let out = (dir ?? defaultRoot.appendingPathComponent("phrases-" + stamp()))
        note("echo-capture phrases: say each phrase when asked, as you would to cut Control off. Into \(out.path)")
        let recorder = AudioRecorder()
        let tape = Tape()
        recorder.setListener { data, hostTime in tape.append(data, hostTime: hostTime) }
        try? await Task.sleep(for: .seconds(1.5))
        var saved: [[String: Any]] = []
        for (i, phrase) in phrases.enumerated() {
            note("  \(i + 1)/\(phrases.count) — say now: \"\(phrase)\"")
            let start = tape.count
            try? await Task.sleep(for: .seconds(3))
            let clip = Array(tape.snapshot.samples[start...])
            let name = String(format: "phrase-%02d.wav", i + 1)
            do { try save(clip, to: out.appendingPathComponent(name)) } catch { note("could not save: \(error)"); exit(1) }
            saved.append(["file": name, "text": phrase, "db": rounded(rmsDb(clip[...]))])
        }
        recorder.setListener(nil)
        do {
            try save(JSONSerialization.data(withJSONObject: ["phrases": saved], options: [.prettyPrinted, .sortedKeys]),
                     to: out.appendingPathComponent("phrases.json"))
        } catch { note("could not save: \(error)"); exit(1) }
        note("echo-capture phrases: saved to \(out.path)")
    }

    // MARK: - Replaying offline

    /// Each reply: how much of it the speech detector takes for speech, raw and
    /// through the canceller. Then, with phrases: each laid over each reply
    /// half a second, two seconds and four seconds in (or less, for a short
    /// one), cancelled, and what Apple's model hears in the second and a half
    /// from the phrase's start — the clip the trigger-word check gets.
    static func replay(_ dir: URL, phrases phrasesDir: URL?) async {
        func load(_ name: String) -> [Int16]? {
            (try? WAVFile(contentsOf: dir.appendingPathComponent(name))).map { HandsFreeService.samples($0.samples) }
        }
        guard let mic = load("mic.wav"), let reference = load("reference.wav"),
              let json = try? Data(contentsOf: dir.appendingPathComponent("capture.json")),
              let summary = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let takes = summary["takes"] as? [[String: Any]] else {
            note("echo-replay: \(dir.path) has no mic.wav, reference.wav and capture.json from --echo-capture"); exit(1)
        }
        let lead = Int(EchoCanceller.leadSeconds * EchoReference.sampleRate)
        let early = [Int16](repeating: 0, count: lead) + reference.dropLast(lead)
        let aec = cancel(mic, reference: early)
        print("echo-replay: \(summary["output"] ?? "?") (\(summary["route"] ?? "?"))")
        print("reply  speech% raw → cancelled   longest ms raw → cancelled   text")
        for (i, take) in takes.enumerated() {
            let range = (take["startSample"] as? Int ?? 0)..<min(take["endSample"] as? Int ?? 0, mic.count, aec.count)
            let raw = speech(Array(mic[range])), clean = speech(Array(aec[range]))
            print(String(format: "%5d  %6d → %-9d   %10d → %-9d   %@", i + 1, raw.percent, clean.percent,
                         raw.longestMs, clean.longestMs, Log.clip(take["text"] as? String ?? "")))
        }
        guard let phrasesDir else { return }
        guard let pjson = try? Data(contentsOf: phrasesDir.appendingPathComponent("phrases.json")),
              let plist = ((try? JSONSerialization.jsonObject(with: pjson)) as? [String: Any])?["phrases"] as? [[String: Any]] else {
            note("echo-replay: \(phrasesDir.path) has no phrases.json from --echo-capture phrases"); exit(1)
        }
        print("\nphrase over reply, cancelled: what the trigger-word check would hear")
        for (i, take) in takes.enumerated() {
            let start = take["startSample"] as? Int ?? 0, end = min(take["endSample"] as? Int ?? 0, mic.count)
            for p in plist {
                guard let file = p["file"] as? String,
                      let voice = (try? WAVFile(contentsOf: phrasesDir.appendingPathComponent(file))).map({ HandsFreeService.samples($0.samples) })
                else { continue }
                for offsetSeconds in [0.5, 2.0, 4.0] {
                    let at = start + Int(offsetSeconds * EchoReference.sampleRate)
                    guard at + voice.count <= end else { continue }
                    var mixed = Array(mic[start..<end])
                    for j in voice.indices { mixed[at - start + j] = Int16(clamping: Int(mixed[at - start + j]) + Int(voice[j])) }
                    let cleaned = cancel(mixed, reference: Array(early[start..<end]))
                    let clipStart = max(0, at - start - Int(0.2 * EchoReference.sampleRate))
                    let clip = Array(cleaned[clipStart..<min(cleaned.count, clipStart + Int(1.5 * EchoReference.sampleRate))])
                    let heard: String
                    do {
                        heard = try await WakeWordCheck.check(pcm: HandsFreeService.data(clip), sampleRate: HandsFreeAudio.sampleRate,
                                                              word: "control", match: .speech).heard
                    } catch { heard = "(check failed: \(error))" }
                    let verdict = HandsFreePhrases.judge(heard, triggers: ["control"])
                    print(String(format: "reply %d +%.1fs  %@  said \"%@\" → heard \"%@\"", i + 1, offsetSeconds,
                                 verdict.trigger != nil ? "CUT IN " : "missed ", p["text"] as? String ?? "", heard))
                    let name = String(format: "mixes/reply%d-%@-%.1fs.wav", i + 1, (file as NSString).deletingPathExtension, offsetSeconds)
                    try? save(cleaned, to: dir.appendingPathComponent(name))
                }
            }
        }
    }

    // MARK: - Inside

    static func cancel(_ mic: [Int16], reference: [Int16]) -> [Int16] {
        let canceller = EchoCanceller()
        var out = canceller.process(mic: mic, reference: Array(reference.prefix(mic.count)))
        if out.count < mic.count { out += [Int16](repeating: 0, count: mic.count - out.count) }
        return out
    }

    /// The speech detector over `pcm`: how much of it is speech, and the longest run.
    private static func speech(_ pcm: [Int16]) -> (percent: Int, longestMs: Int) {
        guard let url = SileroVAD.bundledModelURL(), let vad = try? SileroVAD(modelURL: url) else { return (-1, -1) }
        var frames = 0, speechFrames = 0, run = 0, longest = 0
        var at = 0
        while at + HandsFreeAudio.frameSamples <= pcm.count {
            let p = (try? vad.score(Array(pcm[at..<at + HandsFreeAudio.frameSamples]))) ?? 0
            frames += 1
            if p >= SpeechGate.start { speechFrames += 1; run += 1; longest = max(longest, run) } else { run = 0 }
            at += HandsFreeAudio.frameSamples
        }
        return (100 * speechFrames / max(1, frames), Int(Double(longest) * HandsFreeAudio.frameMs))
    }

    private static func rmsDb(_ pcm: ArraySlice<Int16>) -> Double {
        guard !pcm.isEmpty else { return -120 }
        let sum = pcm.reduce(0.0) { $0 + Double($1) * Double($1) }
        let rms = (sum / Double(pcm.count)).squareRoot() / 32768
        return rms > 0 ? 20 * log10(rms) : -120
    }

    private static func rounded(_ db: Double) -> Double { (db * 10).rounded() / 10 }
}
