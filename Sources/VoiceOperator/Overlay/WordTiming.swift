import Foundation

/// One spoken word and where it lands in the utterance's audio, in seconds from
/// the first audible sample. Produced by the Kokoro server's `/timestamps`
/// endpoint (its duration predictor assigns frames to every phoneme before the
/// vocoder runs) and consumed by the word-highlight overlay.
struct WordTiming: Sendable, Equatable {
    let word: String
    /// Seconds from the utterance's first audible sample.
    let start: Double
    let end: Double
}

/// The Optimal Recognition Point: the letter a reader's eye should be parked on
/// for a given word, so single-word RSVP displays can pin that letter to one
/// fixed on-screen focal point instead of re-centring the whole word each time.
///
/// The pivot sits slightly left of centre (~20–33% into the word). This is the
/// canonical Spritz / OpenSpritz step table — a discretisation of that ratio
/// grounded in Brysbaert & Nazir's reading research — indexed by letter count.
enum ORP {
    /// Zero-based index of the pivot letter for a word of `length` letters.
    static func pivotIndex(forLength length: Int) -> Int {
        switch length {
        case ..<2:   return 0   // 0–1 letters: the letter itself
        case 2...5:  return 1
        case 6...9:  return 2
        case 10...13: return 3
        default:     return 4   // 14+ letters
        }
    }
}
