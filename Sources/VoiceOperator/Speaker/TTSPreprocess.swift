import Foundation

/// A sentence prepared for TTS: what to actually speak (`ttsText`) plus a map
/// from each UTF-16 unit of `ttsText` back to a UTF-16 offset in `original`, so
/// the overlay can display the original text while highlighting whichever piece
/// is being spoken — including a `/` or `.` that was spoken as a whole word.
struct TTSPrepared: Sendable, Equatable {
    let original: String
    let ttsText: String
    /// `origPositions[i]` is the UTF-16 offset in `original` that the i-th UTF-16
    /// unit of `ttsText` came from. Inserted words ("slash", "dot") and the
    /// spaces around them all point back at the single separator character, so a
    /// token like "slash" maps to the literal `/`'s one-character range.
    let origPositions: [Int]
}

/// Rewrites a sentence before it goes to the TTS engine so it is spoken clearly
/// and the overlay can step through it, while still displaying the ORIGINAL text
/// (the overlay maps the timing tokens back through `origPositions`).
///
/// - `/` between alphanumerics is spoken as "slash" (`src/main` → "src slash
///   main"); the overlay highlights the literal `/` when it is said.
/// - `.` between alphanumerics, inside a whitespace-token that also contains `/`
///   (a path), is spoken as "dot" (`app.swift` → "app dot swift"). Other dots —
///   sentence ends, decimals, abbreviations — are left alone.
/// - `-` and `_` between alphanumerics become spaces, so each side is its own
///   spoken/timed token (`state-of-the-art`); the separators show dim.
/// - `*` is dropped, so markdown emphasis isn't read aloud as "asterisk".
/// - `.` before a known source-file extension is spoken as "dot" even without a
///   slash (`foo.ts`), because a bare filename is as common in speech as a path.
/// - `camelCase` and `PascalCase` gain a space at each lowercase→uppercase seam,
///   so `cleanTerminalCopy` is three spoken words rather than one long noise.
/// - A run of 2+ capitals is either lowercased or spelled out letter by letter,
///   decided per word: `JSON` reads as a word, `TTS` as three letters.
///
/// The last three rules arrived from spaceterm, which applied them to terminal
/// text before handing it over. They belong here instead: every rewrite up there
/// happened *outside* the offset map, so the overlay highlighted — and an
/// interrupt landed on — a position in a string the speaker never saw. Doing it
/// here keeps `origPositions` honest, and every client gets it rather than the
/// one that remembered to ask.
///
/// Every rule needs an alphanumeric on the relevant side(s), so a leading minus
/// (`-5`), a spaced dash (`a - b`), and a trailing slash (`dir/`) are left alone.
enum TTSPreprocess {
    /// Extensions whose leading `.` is spoken as "dot" outside a path.
    ///
    /// A list rather than a pattern because the general shape — a dot between
    /// alphanumerics — is also `e.g.`, `3.14`, and the end of a sentence. Those
    /// must stay untouched, and no heuristic separates them from `foo.ts`
    /// reliably enough to risk reading prose wrong.
    static let spokenExtensions: Set<String> = [
        "TS", "TSX", "JS", "JSX", "JSON", "MD", "SWIFT", "PY", "GO", "SH",
        "CSS", "HTML", "YML", "YAML", "TOML", "RS", "TXT",
    ]

    /// Capital runs to read as a word, overriding the heuristic below.
    ///
    /// Two kinds live here. `URL` is the classic acronym that sounds better as
    /// one syllable than as three letters. The rest are ordinary short words
    /// that only appear capitalised for emphasis — prose, not acronyms — and
    /// spelling out "D. O. N. O. T." is a far worse failure than pronouncing an
    /// acronym as a word.
    static let forcePronounce: Set<String> = [
        "URL", "GO", "NO", "DO", "SO", "UP", "IT", "IS", "IF", "ME", "WE", "BE",
        "AT", "ON", "IN", "AN", "AS", "OR", "OK", "TO",
    ]

    /// Capital runs to always spell out, overriding the heuristic.
    ///
    /// Empty: the heuristic already spells out `API`, `IDE`, `TTS` and friends.
    /// It exists for the acronym that happens to look pronounceable.
    static let forceSpellOut: Set<String> = []
    static func prepare(_ original: String) -> TTSPrepared {
        let chars = Array(original)
        // UTF-16 offset of each Character in `original`.
        var offset = [Int](); offset.reserveCapacity(chars.count)
        var acc = 0
        for c in chars { offset.append(acc); acc += c.utf16.count }

        func alnum(_ c: Character) -> Bool { c.isLetter || c.isNumber }

        // Characters inside a whitespace-delimited run containing "/", i.e. a
        // path — the only place a "." is spoken as "dot".
        var inPath = [Bool](repeating: false, count: chars.count)
        var i = 0
        while i < chars.count {
            if chars[i].isWhitespace { i += 1; continue }
            var j = i, slash = false
            while j < chars.count, !chars[j].isWhitespace { if chars[j] == "/" { slash = true }; j += 1 }
            if slash { for k in i..<j { inPath[k] = true } }
            i = j
        }

        // ASCII-only, deliberately: these rules are about code-shaped text, and
        // `isUppercase` is true for Greek and Cyrillic too, where spelling a
        // word out letter by letter would be nonsense.
        func upper(_ c: Character) -> Bool { c.isASCII && c.isUppercase && c.isLetter }
        func lower(_ c: Character) -> Bool { c.isASCII && c.isLowercase && c.isLetter }
        func digit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

        /// Whether this character is emitted as a separator — a space, or a
        /// spoken "slash"/"dot". Both end a word as far as the rules below care.
        func isSpokenSeparator(_ idx: Int) -> Bool {
            let c = chars[idx]
            guard c == "/" || c == "." || c == "-" || c == "_" else { return false }
            let between = idx > 0 && alnum(chars[idx - 1])
                && idx + 1 < chars.count && alnum(chars[idx + 1])
            guard between else { return false }
            if c == "." { return inPath[idx] || isExtensionDot(idx) }
            return true
        }

        /// A `.` that introduces a known source-file extension, e.g. the dot in
        /// `foo.ts` or `foo.ts:42` — the extension must end the word, so the
        /// `.ts` in `foo.tsx` is not one.
        func isExtensionDot(_ idx: Int) -> Bool {
            var end = idx + 1
            while end < chars.count, alnum(chars[end]) { end += 1 }
            guard end > idx + 1 else { return false }
            let ext = String(chars[(idx + 1)..<end]).uppercased()
            return spokenExtensions.contains(ext)
        }

        /// Where a space is inserted for a camelCase seam: an uppercase letter
        /// directly after a lowercase letter or digit.
        var camelSeam = [Bool](repeating: false, count: chars.count)
        for idx in 1..<max(chars.count, 1) where upper(chars[idx]) {
            camelSeam[idx] = lower(chars[idx - 1]) || digit(chars[idx - 1])
        }

        /// What to do with each character of a run of capitals.
        enum CapsAction { case none, lowercase, spellOut }
        var capsAction = [CapsAction](repeating: .none, count: chars.count)

        // A spoken extension is ruled on like any other short word: `.ts` is
        // two letters and spells out, `.json` is a word. Done before the
        // capital runs so a lowercase extension reaches the same decision an
        // uppercase acronym would — the listener cannot hear the difference
        // between `FOO.TS` and `foo.ts`, so neither should this.
        for idx in chars.indices where chars[idx] == "." && isSpokenSeparator(idx) {
            var end = idx + 1
            while end < chars.count, alnum(chars[end]) { end += 1 }
            let ext = String(chars[(idx + 1)..<end]).uppercased()
            guard spokenExtensions.contains(ext), capsDecision(ext) == .spellOut else { continue }
            for k in (idx + 1)..<end { capsAction[k] = .spellOut }
        }

        var runStart = 0
        while runStart < chars.count {
            guard upper(chars[runStart]) else { runStart += 1; continue }
            var runEnd = runStart
            while runEnd < chars.count, upper(chars[runEnd]) { runEnd += 1 }
            let length = runEnd - runStart
            defer { runStart = runEnd }
            guard length >= 2 else { continue }

            // The run has to be a whole word. A capital run that runs straight
            // into lowercase or digits is part of something longer —
            // `HTTPserver`, `ID2` — and rewriting half a token is worse than
            // leaving it: the listener hears a word split down the middle.
            // A separator on either side counts as a boundary because it is
            // emitted as one; a `_` that survives (`__INIT__`) does not.
            let openBoundary = runStart == 0
                || isSpokenSeparator(runStart - 1)
                || camelSeam[runStart]
                || !(alnum(chars[runStart - 1]) || chars[runStart - 1] == "_")
            let closeBoundary = runEnd == chars.count
                || isSpokenSeparator(runEnd)
                || !(alnum(chars[runEnd]) || chars[runEnd] == "_")
            guard openBoundary, closeBoundary else { continue }

            let word = String(chars[runStart..<runEnd])
            let action: CapsAction = capsDecision(word) == .lowercase ? .lowercase : .spellOut
            for k in runStart..<runEnd { capsAction[k] = action }
        }

        var units = [UInt16](); units.reserveCapacity(chars.count)
        var pos = [Int](); pos.reserveCapacity(chars.count)
        // Inserted text: every unit points back at the source character `o`.
        func emit(_ s: String, from o: Int) { for u in s.utf16 { units.append(u); pos.append(o) } }
        // Verbatim: units keep their own offsets so a word maps back exactly.
        func verbatim(_ c: Character, at o: Int) {
            var k = 0
            for u in c.utf16 { units.append(u); pos.append(o + k); k += 1 }
        }

        for (idx, c) in chars.enumerated() {
            let o = offset[idx]
            let prevAlnum = idx > 0 && alnum(chars[idx - 1])
            let nextAlnum = idx + 1 < chars.count && alnum(chars[idx + 1])
            let between = prevAlnum && nextAlnum

            // The camel seam's space maps back to the capital that caused it,
            // so highlighting the second word still lands on its first letter.
            if camelSeam[idx] { emit(" ", from: o) }

            switch capsAction[idx] {
            case .lowercase:
                emit(String(c).lowercased(), from: o)
                continue
            case .spellOut:
                // Each letter gets its own period: "T T S" is slurred back into
                // a syllable by every engine tried, "T. T. S." is not. The
                // trailing space is dropped at the end of the run so the next
                // character's own spacing still reads normally.
                // Uppercased: a spelled-out extension is lowercase in the
                // source (`foo.ts`), and "t." is read as a word, not a letter.
                let letter = String(c).uppercased()
                emit(idx + 1 < chars.count && capsAction[idx + 1] == .spellOut
                     ? "\(letter). " : "\(letter).", from: o)
                continue
            case .none:
                break
            }

            switch c {
            case "/" where between:                     emit(" slash ", from: o)
            case "." where between && (inPath[idx] || isExtensionDot(idx)):
                                                        emit(" dot ", from: o)
            case "-" where between, "_" where between:   emit(" ", from: o)
            case "*":                                    break   // dropped: never spoken
            default:                                     verbatim(c, at: o)
            }
        }
        return TTSPrepared(original: original,
                           ttsText: String(utf16CodeUnits: units, count: units.count),
                           origPositions: pos)
    }

    /// Just the text to synthesize (for callers that don't need the map).
    static func ttsText(_ original: String) -> String { prepare(original).ttsText }

    /// Whether a run of capitals is a word to pronounce or letters to spell.
    ///
    /// The engine cannot be left to decide: given `FEATURE` it spells, given
    /// `TTS` it invents a syllable ("teets"). So each word is ruled on here.
    ///
    /// The heuristic is phonotactic, and deliberately conservative about what
    /// it will call a word: four or more letters with a vowel is a word
    /// (`JSON`, `YAML`, `LERP`), and exactly three is a word only in the two
    /// shapes that reliably carry one syllable — consonant-vowel-consonant
    /// (`GAP`, `BAR`) and vowel-vowel-consonant (`OUT`, `AIM`). Both end on a
    /// consonant, which is the signal. Vowel-consonant-vowel is excluded even
    /// though it catches real words, because `API`, `IDE` and `USA` all sit
    /// there and acronyms are the commoner case in this app's input. Two
    /// letters spell out, which is why the short prose words are listed in
    /// `forcePronounce` rather than reasoned about here.
    static func capsDecision(_ word: String) -> CapsDecision {
        if forcePronounce.contains(word) { return .lowercase }
        if forceSpellOut.contains(word) { return .spellOut }
        return isPronounceable(word) ? .lowercase : .spellOut
    }

    /// The outcome of `capsDecision`, mirrored by the private per-character
    /// enum inside `prepare`.
    enum CapsDecision { case lowercase, spellOut }

    private static func isPronounceable(_ word: String) -> Bool {
        let vowels = Set("AEIOU")
        guard word.contains(where: { vowels.contains($0) }) else { return false }
        if word.count >= 4 { return true }
        guard word.count == 3 else { return false }
        let c = Array(word)
        let isVowel = { (ch: Character) in vowels.contains(ch) }
        // Y counts as a consonant here, so SKY spells out.
        let cvc = !isVowel(c[0]) && isVowel(c[1]) && !isVowel(c[2])
        let vvc = isVowel(c[0]) && isVowel(c[1]) && !isVowel(c[2])
        return cvc || vvc
    }
}
