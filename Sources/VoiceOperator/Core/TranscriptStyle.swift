import Foundation

/// How a dictation's transcript is post-processed before it is recorded and
/// pasted — an **ephemeral, per-dictation** setting cycled with a tap of the left
/// Shift key while recording (`HotkeyMonitor`). It exists only for the dictation
/// in flight; the next one starts back at `.normal`.
///
/// ## Why
///
/// Wispr Flow returns a finished *sentence*: first word capitalised, a full stop
/// at the end. That is right when the transcript stands alone and wrong when it is
/// being injected into the middle of something already written, where the same
/// text wants to read as a fragment. Fixing that by hand after every paste is the
/// thing this avoids: you decide while you are still speaking, and the transcript
/// arrives shaped the way it needs to be.
///
/// The two shaping flags are independent, then the final tap selects a discard
/// state: `normal → lowercaseFirst → both → trimTrailingPunctuation → discard →
/// normal`. Discard is deliberately its own state: it still transcribes and
/// records the result, but it does not insert it into the focused app.
///
/// ## The spaces are deliberate
///
/// Both flags add whitespace around the fragment, because both mean "this is
/// going into the middle of a line" and the caret is rarely parked with the
/// spacing already correct. A doubled space costs nothing where this text is
/// headed (prompts, chat boxes), whereas a missing one welds two words together.
struct TranscriptStyle: Equatable, Sendable {
    /// Lowercase the transcript's first word (and prefix a space), so it reads as
    /// a continuation rather than the start of a sentence.
    var lowercaseFirst = false
    /// Drop the sentence-final punctuation and guarantee one trailing space, so
    /// what follows continues the same sentence.
    var trimTrailingPunctuation = false
    /// Suppress insertion after transcription. This is never combined with a
    /// shaping flag: the cycle shows it as a distinct trash state.
    var discard = false

    init(lowercaseFirst: Bool = false, trimTrailingPunctuation: Bool = false, discard: Bool = false) {
        self.discard = discard
        self.lowercaseFirst = discard ? false : lowercaseFirst
        self.trimTrailingPunctuation = discard ? false : trimTrailingPunctuation
    }

    static let normal = TranscriptStyle()

    var isNormal: Bool { self == .normal }

    /// The cycle, in tap order. Each step flips one flag.
    private static let cycle: [TranscriptStyle] = [
        TranscriptStyle(lowercaseFirst: false, trimTrailingPunctuation: false),
        TranscriptStyle(lowercaseFirst: true,  trimTrailingPunctuation: false),
        TranscriptStyle(lowercaseFirst: true,  trimTrailingPunctuation: true),
        TranscriptStyle(lowercaseFirst: false, trimTrailingPunctuation: true),
        TranscriptStyle(discard: true),
    ]

    /// The state one tap of the left Shift key moves to.
    var next: TranscriptStyle {
        let i = Self.cycle.firstIndex(of: self) ?? 0
        return Self.cycle[(i + 1) % Self.cycle.count]
    }

    /// For the status item's accessibility description.
    var accessibilityLabel: String {
        if discard { return "discard transcript" }
        switch (lowercaseFirst, trimTrailingPunctuation) {
        case (false, false): return "normal"
        case (true, false):  return "lowercase first word"
        case (true, true):   return "lowercase first word, trim end punctuation"
        case (false, true):  return "trim end punctuation"
        }
    }

    /// Where a finished transcript goes. The discard check comes first, so it
    /// holds for commands as well as dictation.
    func delivery(of transcript: String, command: Bool) -> TranscriptDelivery {
        // Emptiness is judged on the transcript, not on the styled text: the
        // style adds spaces, and " " must not paste as if it were speech.
        if discard || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .none }
        // A command is spoken to the router, not written into a document, so the
        // fragment-shaping the style does would only confuse it.
        return command ? .route(transcript) : .paste(apply(to: transcript))
    }

    /// Terminal punctuation the trim flag removes. `!` and `?` are included at the
    /// user's request: they are as much an artefact of the formatter's
    /// sentence-shaping as the full stop is.
    private static let terminalPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?"]

    /// Shape `text` for insertion. Pure, and a no-op for `.normal` — callers can
    /// apply it unconditionally.
    func apply(to text: String) -> String {
        guard !isNormal, !text.isEmpty else { return text }
        var s = text

        if trimTrailingPunctuation {
            trimTrailingWhitespace(&s)
            if let last = s.last, Self.terminalPunctuation.contains(last) { s.removeLast() }
            // A space *before* the punctuation ("the cat sat .") would otherwise
            // survive as a double space once we append our own.
            trimTrailingWhitespace(&s)
            s += " "
        }

        if lowercaseFirst {
            if let i = s.firstIndex(where: { !$0.isWhitespace }), Self.shouldLowercase(s, at: i) {
                let folded = s[i].lowercased()
                s.replaceSubrange(i...i, with: folded)
            }
            if s.first?.isWhitespace != true { s = " " + s }
        }

        return s
    }

    private func trimTrailingWhitespace(_ s: inout String) {
        while let last = s.last, last.isWhitespace { s.removeLast() }
    }

    /// Whether the character at `i` — the first non-blank of the transcript — is
    /// one we should case-fold.
    ///
    /// Two words must be left alone even though they are capitalised, because
    /// their capital is not the formatter's sentence-shaping but part of the word:
    /// an acronym (`API is broken` → not `aPI is broken`) and the pronoun `I`.
    /// Note that a lone `A` is *not* exempt — "A cat sat" really does want to
    /// become "a cat sat" mid-sentence.
    private static func shouldLowercase(_ s: String, at i: String.Index) -> Bool {
        guard s[i].isUppercase else { return false }
        // The word's leading run of letters, so trailing punctuation ("API,") and
        // contractions ("I'll") are both judged on the part that matters.
        let head = s[i...].prefix { $0.isLetter }
        if head.count > 1, head.allSatisfy(\.isUppercase) { return false }   // acronym
        if head == "I" { return false }                                      // the pronoun, and I'll/I'm/I've
        return true
    }
}

/// What becomes of a finished transcript: see `TranscriptStyle.delivery`.
enum TranscriptDelivery: Equatable {
    /// Nothing was said, or the user discarded it: record it, send it nowhere.
    case none
    /// A command's text, unshaped, for the router.
    case route(String)
    /// Styled text to paste into the focused app.
    case paste(String)
}
