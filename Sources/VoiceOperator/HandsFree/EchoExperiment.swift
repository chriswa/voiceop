import Foundation

/// Where a hands-free source's sound goes, as far as its microphone is
/// concerned: into an ear (`ear` — AirPods, a headset, headphones), into the
/// room where the microphone hears it (`open` — the Mac's or the phone's own
/// speaker), or somewhere this cannot tell (`unsure` — a monitor's speakers, a
/// Bluetooth speaker or a car, AirPlay). Shown on the client's hands-free
/// button (`setup`), and the only place the echo experiment acts is `open`.
enum AudioRoute: String, Sendable { case ear, open, unsure }

/// Hands-free's experimental echo cancellation: off by default, a checkbox in
/// the menu. Off, hands-free stands aside while our own voice plays where the
/// microphone hears it, exactly as before. On, on an `open` route only, it
/// listens through it:
///
/// - **Mac:** the microphone goes through a software echo canceller
///   (`EchoCanceller`, SpeexDSP) fed what Voice Operator is playing
///   (`EchoReference`). Headsets are untouched.
/// - **Phone:** the phone's own echo cancellation (voice processing), which it
///   already runs on its speaker, is trusted — after the start of each reply,
///   where it leaked.
///
/// Both, while our voice plays or rings out (`HandsFreeEngine.SourceState.throughEcho`):
/// the first `settleMs` of each reply is not listened to; only the trigger word
/// cuts in, even in the conversation window; speech that matches what was just
/// said (`RecentSpeech`) is taken for echo; and nothing heard there gets a cue.
/// DESIGN.md, "Echo cancellation experiment".
enum EchoExperiment {
    private static let key = "vo.handsFreeEchoExperiment"

    /// The checkbox. Read on any thread; `HandsFreeService.host.echoExperiment` carries it to hands-free.
    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The start of each reply, not listened to: echo cancellation leaked the
    /// first words of a reply (608 ms in, October 25) before it had adapted.
    static let settleMs: Double = 1000
}

/// What our own voice has said lately, on the Mac or sent to a device, for
/// telling echo from the user: speech heard through the echo canceller whose
/// words are a run of what was just said is our voice, not theirs. In memory
/// only, and only the last `keepSeconds`.
final class RecentSpeech: @unchecked Sendable {
    static let shared = RecentSpeech()
    static let keepSeconds: TimeInterval = 60
    /// Heard words compared, at most: the start of what was heard is enough.
    static let comparedWords = 4

    private let lock = NSLock()
    private var said: [(at: Date, words: [String])] = []

    func note(_ text: String, at: Date = Date()) {
        let words = HandsFreePhrases.spokenWords(text)
        guard !words.isEmpty else { return }
        lock.withLock {
            said.append((at, words))
            said.removeAll { at.timeIntervalSince($0.at) > Self.keepSeconds }
        }
    }

    /// Whether `heard` is a run of what was said lately: two words or more,
    /// in order, inside one sentence. One word alone ("Control.") cannot say.
    func isEcho(_ heard: String, now: Date = Date()) -> Bool {
        let words = Array(HandsFreePhrases.spokenWords(heard).prefix(Self.comparedWords))
        guard words.count >= 2 else { return false }
        let recent = lock.withLock { said.filter { now.timeIntervalSince($0.at) <= Self.keepSeconds } }
        return recent.contains { Self.contains($0.words, words) }
    }

    func clear() { lock.withLock { said = [] } }

    private static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }
}
