import Foundation

/// Wispr's client-side Baseten `Api-Key` (the `baseten-authorization` metadata on
/// the gRPC transcription path). It is baked into Wispr's distributed app, but we
/// deliberately do NOT commit it to this repo. Supplied at runtime, in order:
///   1. `VOICEOP_BASETEN_KEY` environment variable (CLI/tests), or
///   2. `~/Library/Application Support/VoiceOperator/baseten-key` (the GUI app,
///      launched via `open`, doesn't inherit the shell env).
/// When absent, `WisprFlowTranscriber` falls back to the raw `/llm/asr` path.
enum WisprBasetenKey {
    static var value: String? {
        if let v = ProcessInfo.processInfo.environment["VOICEOP_BASETEN_KEY"], !v.isEmpty {
            return v
        }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceOperator/baseten-key")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}
