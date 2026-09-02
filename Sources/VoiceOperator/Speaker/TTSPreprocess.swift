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
///
/// Every rule needs an alphanumeric on the relevant side(s), so a leading minus
/// (`-5`), a spaced dash (`a - b`), and a trailing slash (`dir/`) are left alone.
enum TTSPreprocess {
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
            switch c {
            case "/" where between:                     emit(" slash ", from: o)
            case "." where between && inPath[idx]:       emit(" dot ", from: o)
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
}
