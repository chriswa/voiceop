import Foundation

/// What hands-free makes of the words Apple's on-device model heard in a clip:
/// whether they began with a client's trigger word, whether they were words at
/// all rather than a cough or filler, and whether they were one of the phrases
/// that end the conversation hands-free, or "stop listening", which ends the
/// conversation window.
///
/// Spaceterm used to judge all of this itself, behind `/v1/wake-word`
/// (`src/server/hands-free.ts`, `src/shared/control-shutdown.ts`); it moved here
/// with the rest of hands-free so that every client gets the same answers.
enum HandsFreePhrases {
    /// Sounds Apple's model writes down as words that are not anyone saying
    /// anything: filler, and what it hears in a cough or a breath. Speech made
    /// only of these does not start a dictation in the conversation window.
    static let ignoredWords: [String] = ["hmm", "hm", "mm", "mmm", "mhm", "uh", "um", "er", "ah", "uh-huh"]

    /// "Let me turn this off" — said to someone in the room, it reads as the
    /// user dealing with their phone — ends the conversation without a trigger
    /// word. "<trigger>, shutdown" does the same after the trigger word.
    static let letMeTurnThisOff = ["let", "me", "turn", "this", "off"]

    /// Lowercased words, punctuation dropped (apostrophes and hyphens kept).
    static func spokenWords(_ text: String) -> [String] {
        let kept = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
                || scalar == "'" || scalar == "-" ? Character(scalar) : " "
        }
        return String(kept).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// `words` with every ignored word or phrase ("thank you") taken out,
    /// wherever it falls. Longer phrases are tried first.
    static func withoutIgnored(_ words: [String], ignored: [String] = ignoredWords) -> [String] {
        let phrases = ignored.map(spokenWords).filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        var out: [String] = []
        var i = 0
        while i < words.count {
            if let phrase = phrases.first(where: { phrase in
                phrase.indices.allSatisfy { i + $0 < words.count && words[i + $0] == phrase[$0] }
            }) {
                i += phrase.count
            } else {
                out.append(words[i])
                i += 1
            }
        }
        return out
    }

    /// The trigger word the words begin with, if any of `triggers` — the first
    /// word only: "Control, what's Kevin doing" counts; "under control" and
    /// "controller" do not.
    static func trigger(in heard: String, among triggers: [String]) -> String? {
        guard let first = spokenWords(heard).first else { return nil }
        return triggers.first { spokenWords($0) == [first] }
    }

    /// Lowercased letters-only words, "lemme" as dictation sometimes writes "let me".
    static func phraseWords(_ text: String) -> [String] {
        let kept = text.lowercased().unicodeScalars.map { CharacterSet.letters.contains($0) ? Character($0) : " " }
        return String(kept).split(whereSeparator: \.isWhitespace).flatMap { word -> [String] in
            word == "lemme" ? ["let", "me"] : [String(word)]
        }
    }

    /// Whether `text` — a whole dictation, or a whole burst of speech — is a
    /// phrase that ends the conversation: "let me turn this off", or
    /// "shutdown" ("shut down", "shut-down"), each optionally after `trigger`.
    /// Only the phrase on its own counts, never words inside a longer request.
    static func isShutdown(_ text: String, trigger: String?) -> Bool {
        let words = phraseWords(text, after: trigger)
        return words.joined() == "shutdown" || words == letMeTurnThisOff
    }

    /// "Stop listening" — ends the conversation window as if it had run out, so
    /// the trigger word is needed again; hands-free stays on.
    static let stopListening = ["stop", "listening"]

    /// Whether `text`, a whole dictation, is "stop listening", optionally after
    /// `trigger`. Only the phrase on its own counts: "stop listening to Kevin" does not.
    static func isStopListening(_ text: String, trigger: String?) -> Bool {
        phraseWords(text, after: trigger) == stopListening
    }

    /// `phraseWords` with `trigger` taken off the front, if it is there.
    private static func phraseWords(_ text: String, after trigger: String?) -> [String] {
        var words = phraseWords(text)
        if let trigger, let first = words.first, phraseWords(trigger) == [first] { words.removeFirst() }
        return words
    }

    /// A burst heard while listening for a trigger word, against "let me turn
    /// this off" said without one: `.whole` — the phrase and nothing else;
    /// `.start` — at least "let me", as the first second of it may be heard, so
    /// the whole burst is worth checking once it ends. Nil otherwise, including
    /// "shutdown" alone, which counts only after the trigger word or in the
    /// conversation window.
    enum WakeFreeShutdown: String, Sendable { case whole, start }

    static func wakeFreeShutdown(_ heard: String) -> WakeFreeShutdown? {
        let words = phraseWords(heard)
        if words == letMeTurnThisOff { return .whole }
        return words.count >= 2 && words.count <= letMeTurnThisOff.count
            && Array(letMeTurnThisOff.prefix(words.count)) == words ? .start : nil
    }

    /// What a check of a candidate clip came to.
    struct Verdict: Equatable, Sendable {
        /// The trigger word it began with, if any.
        var trigger: String?
        /// Real words, filler aside — what the conversation window needs.
        var words: Bool
        var shutdown: WakeFreeShutdown?
    }

    static func judge(_ heard: String, triggers: [String]) -> Verdict {
        Verdict(trigger: trigger(in: heard, among: triggers),
                words: !withoutIgnored(spokenWords(heard)).isEmpty,
                shutdown: wakeFreeShutdown(heard))
    }
}
