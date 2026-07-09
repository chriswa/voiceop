import Foundation

/// 81 sticky operator call-signs mapped onto the 27 English Kokoro (kokoro-82m)
/// voices the local TTS server exposes — roughly three call-signs per voice, so
/// we have a deep name pool without running short. Each name has a fixed voice
/// (a name always sounds the same), but a voice is shared by several names; the
/// registry prefers to hand each concurrent session a *distinct* voice and only
/// doubles up once all 27 are in use. Every pair's `gender` matches the voice's
/// gender as reported by the Kokoro `/voices` endpoint. The comment above each
/// group is the Kokoro voice id + its catalog label.
///
/// The call-signs are the curated, ASR-round-tripped roster the Cartesia table
/// used, so every name has a `NameAliases.phoneticKey` entry. NameVoiceTableTests
/// asserts name/voice gender alignment — keep it in sync when adding names.
struct NamedVoice: Equatable, Sendable, Codable {
    let name: String
    let voiceID: String
    let gender: VoiceGender
}

/// Gender of a TTS voice, as reported by the provider.
enum VoiceGender: String, Sendable, Codable {
    case masculine
    case feminine
}

enum NameVoiceTable {
    /// Build the group of same-voice call-signs. Keeps each row terse while
    /// making the "N names share this voice" structure obvious.
    private static func voice(_ id: String, _ gender: VoiceGender, _ names: [String]) -> [NamedVoice] {
        names.map { NamedVoice(name: $0, voiceID: id, gender: gender) }
    }

    static let all: [NamedVoice] =
        // ── Female voices (American af_*, British bf_*) ──────────────────────
        voice("af_heart", .feminine, ["Grace", "Claire", "Diana"]) +       // Heart
        voice("af_bella", .feminine, ["Chloe", "Sadie", "Heidi"]) +        // Bella
        voice("bf_emma", .feminine, ["Emma", "Ivy", "Jane"]) +             // Emma (British)
        voice("bf_alice", .feminine, ["Fiona", "Lucy", "Maya"]) +          // Alice (British)
        voice("af_aoede", .feminine, ["Hazel", "Mia", "Daphne"]) +         // Aoede
        voice("af_kore", .feminine, ["Iris", "Nora", "Rose"]) +            // Kore
        voice("af_jessica", .feminine, ["Julia", "Tessa", "Beth"]) +       // Jessica
        voice("af_nicole", .feminine, ["Kate", "Dana", "Gemma"]) +         // Nicole
        voice("bf_lily", .feminine, ["Lily", "Laura", "Wendy"]) +          // Lily (British)
        voice("af_alloy", .feminine, ["Molly", "Bella", "Naomi"]) +        // Alloy
        voice("af_nova", .feminine, ["Nina", "Rita"]) +                    // Nova
        voice("bf_isabella", .feminine, ["Olivia", "Vivian"]) +            // Isabella (British)
        voice("af_river", .feminine, ["Penny", "Ruth"]) +                  // River
        voice("af_sarah", .feminine, ["Rachel", "Piper"]) +                // Sarah
        voice("af_sky", .feminine, ["Stella", "Zoe"]) +                    // Sky
        // ── Male voices (American am_*, British bm_*) ────────────────────────
        voice("am_adam", .masculine, ["Oliver", "Caleb", "Isaac", "Blake"]) +   // Adam
        voice("am_michael", .masculine, ["Jack", "Evan", "Grant", "Kyle"]) +    // Michael
        voice("bm_george", .masculine, ["Henry", "Luke", "Wade", "Harvey"]) +   // George (British)
        voice("am_liam", .masculine, ["Leo", "Leon", "Oscar", "George"]) +      // Liam
        voice("am_echo", .masculine, ["Max", "Jonah", "Roland", "Bruno"]) +     // Echo
        voice("am_onyx", .masculine, ["Noah", "Dean", "Jake"]) +                // Onyx
        voice("am_eric", .masculine, ["Ethan", "Mark", "Miles"]) +              // Eric
        voice("am_puck", .masculine, ["Lucas", "Nathan", "Ross"]) +             // Puck
        voice("am_fenrir", .masculine, ["Mason", "Scott", "Simon"]) +           // Fenrir
        voice("bm_lewis", .masculine, ["Logan", "Vincent", "Wesley"]) +         // Lewis (British)
        voice("bm_daniel", .masculine, ["Marcus", "Wyatt", "Nolan"]) +          // Daniel (British)
        voice("bm_fable", .masculine, ["Victor", "Felix", "Jasper"])            // Fable (British)

    /// The neutral English voice for verbatim, session-less speech (⌘⌃S
    /// speak-the-clipboard) and the debug TTS harness. Resolved by name so
    /// reordering `all` can never silently change which voice this is.
    static let defaultVoice: NamedVoice = all.first { $0.name == "Oliver" } ?? all[0]
}
