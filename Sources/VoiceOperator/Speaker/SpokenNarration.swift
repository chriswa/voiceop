import Foundation

/// How far a voice has got through a narration, as a character position rather
/// than a moment in time.
///
/// The sentence index travels with the offset because the two are only
/// meaningful together, and because playback does not always move forwards: a
/// rewind puts the voice back into a sentence the queue has already left
/// behind, and an offset alone would then be added to the wrong sentence's
/// base. Whoever converts this into a whole-narration position uses the index
/// that came with it, not the one it expected.
struct SpokenPosition: Sendable, Equatable {
    /// Index into the sentences appended to the narration, in append order.
    let sentence: Int
    /// UTF-16 offset into that sentence's original text, one past the last word
    /// the listener heard. UTF-16 because that is what `NSRange` counts and what
    /// every consumer of this — including the JSON clients — indexes strings by.
    let characterOffset: Int
}

/// One word of narration, located both in time and in its sentence's text.
struct SpokenWord: Equatable {
    let sentenceIndex: Int
    /// The sentence as written, not as it was handed to the synthesizer.
    let sentenceText: String
    /// UTF-16 range of this word within `sentenceText`.
    let range: NSRange
    /// UTF-16 offset within `sentenceText` of the word's ORP pivot letter.
    let pivotOffset: Int
}

/// What the voice is saying, word by word, for as long as one speech job lasts.
///
/// Sentences arrive one at a time as the queue reaches them, each pinned to its
/// start on the job's continuous audio timeline, so a lookup by elapsed seconds
/// resolves to a word in a specific sentence however many sentences have been
/// spoken and whether or not the listener has rewound into an earlier one.
///
/// This is a model, not a view: the reading overlay renders from it, and the
/// speech queue asks it where a listener's interruption landed. It sits outside
/// the overlay controller so that discarding the narration and hiding the panel
/// stay separate — the interrupt path needs the first without the second.
@MainActor
final class SpokenNarration {
    private struct WordSpan { let start: Double; let end: Double; let range: NSRange; let pivotOffset: Int }
    private struct Context { let text: String; let spans: [WordSpan] }
    private struct Sentence {
        let start: Double
        var context: Context?
    }

    private var sentences: [Sentence] = []
    /// Discards timing responses still in flight from a narration already
    /// thrown away, which would otherwise land in the next one's sentence list.
    private var session = UUID()
    /// How long a sentence's last word stays current after it stops sounding,
    /// so the display does not blank in the gap before the next sentence.
    private let tailSeconds = 0.3

    var isEmpty: Bool { sentences.isEmpty }

    func reset() {
        session = UUID()
        sentences.removeAll()
    }

    /// Add the sentence starting at `start` seconds into the narration.
    ///
    /// The timings resolve asynchronously — the synthesizer predicts them while
    /// the audio is being made — so the sentence takes its place on the timeline
    /// immediately and fills in when they arrive.
    @discardableResult
    func append(start: Double, prepared: TTSPrepared,
                timings: @escaping @Sendable () async -> [WordTiming]) -> Task<Void, Never> {
        let token = session
        let index = sentences.count
        sentences.append(Sentence(start: start))
        return Task { [weak self] in
            let resolved = await timings()
            guard let self, self.session == token else { return }
            self.sentences[index].context = Self.buildContext(prepared: prepared, words: resolved)
        }
    }

    /// The word being spoken at `seconds`, or nil when nothing is.
    func word(at seconds: Double) -> SpokenWord? {
        guard let (index, context, elapsed) = locate(seconds) else { return nil }
        if let last = context.spans.last, elapsed > last.end + tailSeconds {
            // Do not destroy contexts here: the next key can rewind into them.
            return nil
        }
        guard let spanIndex = context.spans.lastIndex(where: { $0.start <= elapsed }) else { return nil }
        let span = context.spans[spanIndex]
        return SpokenWord(sentenceIndex: index, sentenceText: context.text,
                          range: span.range, pivotOffset: span.pivotOffset)
    }

    /// How much of the sentence in progress at `seconds` the listener has heard.
    ///
    /// A word counts as heard once it has *started*, not once it has finished.
    /// That is the same rule the overlay highlights by, so what a listener saw
    /// lit up when they hit the key is exactly what this reports — and a word
    /// they heard the first half of is one they can act on, which a word they
    /// never heard at all is not.
    ///
    /// Returns nil when the narration has no timings for that moment, which is
    /// the honest answer during the window before a sentence's timings arrive:
    /// the caller then falls back to whole-sentence resolution rather than
    /// reporting a confident zero.
    func spokenPrefix(at seconds: Double) -> SpokenPosition? {
        guard let (index, context, elapsed) = locate(seconds) else { return nil }
        // Past the tail of the last word: the sentence was spoken in full, and
        // its own length is the honest answer rather than its last word's end.
        if let last = context.spans.last, elapsed > last.end {
            return SpokenPosition(sentence: index, characterOffset: (context.text as NSString).length)
        }
        guard let spanIndex = context.spans.lastIndex(where: { $0.start <= elapsed }) else {
            // Interrupted before the first word sounded. Nothing was heard.
            return SpokenPosition(sentence: index, characterOffset: 0)
        }
        return SpokenPosition(sentence: index, characterOffset: NSMaxRange(context.spans[spanIndex].range))
    }

    /// The sentence in progress at `seconds`, if its timings have landed.
    private func locate(_ seconds: Double) -> (index: Int, context: Context, elapsed: Double)? {
        guard let index = sentences.lastIndex(where: { $0.start <= seconds }),
              let context = sentences[index].context, !context.spans.isEmpty else { return nil }
        return (index, context, seconds - sentences[index].start)
    }

    /// Each timed word with its UTF-16 range in the text as written, for a
    /// client that plays the audio itself and so has to work out for itself
    /// where a listener's interruption landed (`/v1/synthesize`).
    ///
    /// Nil when the tokens cannot be aligned against the text. There is no
    /// space-join fallback here: ranges into a text the client never saw would
    /// point at the wrong words, and no ranges is the honest answer.
    nonisolated static func wordRanges(prepared: TTSPrepared, words: [WordTiming]) -> [(timing: WordTiming, range: NSRange)]? {
        guard let context = alignedContext(prepared: prepared, words: words) else { return nil }
        return zip(words, context.spans).map { ($0, $1.range) }
    }

    /// Build the spans for a sentence. Preferred path: align the timing
    /// tokens against the text that was actually synthesized (`prepared.ttsText`)
    /// and map each match back onto the ORIGINAL through `origPositions`, so the
    /// line shows the text as written and a `/` or `.` spoken as a word still
    /// highlights the literal character. If a token can't be located (Kokoro
    /// normalised it), fall back to joining the tokens with spaces, and log it so
    /// the real-world fallback rate is observable.
    private static func buildContext(prepared: TTSPrepared, words: [WordTiming]) -> Context {
        if let aligned = alignedContext(prepared: prepared, words: words) { return aligned }
        if !words.isEmpty {
            Log.log("overlay: token alignment failed, using space-join for \(Log.clip(prepared.original))")
        }
        return joinedContext(words)
    }

    /// Greedy forward substring scan of the timing tokens through `ttsText`, each
    /// match mapped back to an original range via `origPositions`. Returns nil if
    /// any token isn't a substring at/after the cursor, signalling the fallback.
    nonisolated private static func alignedContext(prepared: TTSPrepared, words: [WordTiming]) -> Context? {
        guard !words.isEmpty else { return nil }
        let display = prepared.original as NSString
        let tts = prepared.ttsText as NSString
        let pos = prepared.origPositions
        guard pos.count == tts.length else { return nil }
        var cursor = 0
        var spans: [WordSpan] = []
        for w in words {
            let searchRange = NSRange(location: cursor, length: tts.length - cursor)
            var found = tts.range(of: w.word, options: [], range: searchRange)
            if found.location == NSNotFound {
                found = tts.range(of: w.word, options: [.caseInsensitive], range: searchRange)
            }
            guard found.location != NSNotFound, found.length > 0 else { return nil }
            let start = pos[found.location]
            let end = pos[found.location + found.length - 1] + 1
            guard start >= 0, end > start, end <= display.length else { return nil }
            let range = NSRange(location: start, length: end - start)
            spans.append(WordSpan(start: w.start, end: w.end, range: range,
                                  pivotOffset: pivotOffset(in: display, range: range)))
            cursor = found.location + found.length
        }
        return Context(text: prepared.original, spans: spans)
    }

    /// The pivot to pin on the focal point for a highlighted range: the single
    /// character for a separator (`/`, `.`), else the word's ORP pivot.
    nonisolated private static func pivotOffset(in display: NSString, range: NSRange) -> Int {
        if range.length <= 1 { return range.location }
        return range.location + pivotUTF16Offset(in: display.substring(with: range))
    }

    /// Fallback: join the tokens with single spaces (no original punctuation).
    private static func joinedContext(_ words: [WordTiming]) -> Context {
        var text = ""
        var spans: [WordSpan] = []
        for (i, w) in words.enumerated() {
            if i > 0 { text += " " }
            let wordStart = text.utf16.count
            spans.append(WordSpan(start: w.start, end: w.end,
                                  range: NSRange(location: wordStart, length: w.word.utf16.count),
                                  pivotOffset: wordStart + pivotUTF16Offset(in: w.word)))
            text += w.word
        }
        return Context(text: text, spans: spans)
    }

    /// UTF-16 offset, within `word`, of its ORP pivot letter.
    nonisolated private static func pivotUTF16Offset(in word: String) -> Int {
        let pivot = ORP.pivotIndex(forLength: word.count)
        let charIndex = word.index(word.startIndex, offsetBy: pivot)
        return word.utf16.distance(from: word.utf16.startIndex,
                                   to: charIndex.samePosition(in: word.utf16) ?? word.utf16.startIndex)
    }
}
