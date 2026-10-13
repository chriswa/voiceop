import Foundation

/// Which transcription path dictation is currently getting: the fast gRPC stream
/// (audio uploaded while the user speaks, formatted result moments after key-up)
/// or the slow fallback (the whole clip uploaded to raw `/llm/asr` *after* key-up,
/// unformatted, 5–10 s on a long dictation).
///
/// The fallback is a genuine failure path, not a mode — see
/// `AudioArbiter.transcribe`. It is quiet by nature, though: the words still
/// arrive, just late and unformatted, so the user's only clue used to be a log
/// line. This type is what makes it loud: it drives a menu-bar warning, an icon
/// badge, the key-up cue and the `/v1/status` payload (`DESIGN.md`, "Streaming
/// dictation"; the 2026-09-02 fresh-Mac no-key incident is why it exists).
enum StreamHealth: Equatable, Sendable {
    /// Nothing has exercised the stream yet this session. Shows nothing.
    case unverified
    /// The last dictation was committed over the stream.
    case streaming
    /// The last attempt fell back (Wispr Flow) or failed (Parakeet). `reason` is
    /// the short user message from `TranscriberError.userMessage(for:)`, e.g.
    /// "no Baseten key"; `provider` is the one in trouble — always the primary,
    /// since a struggling shadow is the shadow's business.
    case degraded(reason: String, provider: TranscriptionProviderID = .wisprFlow)

    var isDegraded: Bool { if case .degraded = self { return true } else { return false } }

    var reason: String? { if case .degraded(let r, _) = self { return r } else { return nil } }

    /// The value reported by `/v1/status`.
    var wireName: String {
        switch self {
        case .unverified: return "unverified"
        case .streaming:  return "streaming"
        case .degraded:   return "degraded"
        }
    }

    /// The persistent warning line at the top of the menu, or nil to hide it.
    /// Carries the reason because the two causes want different fixes: a missing
    /// or rotated key is a one-time configuration job, while a stream that opened
    /// and then failed is usually the network or Baseten and clears on its own.
    var menuWarning: String? {
        guard case .degraded(let reason, let provider) = self else { return nil }
        switch provider {
        case .wisprFlow where reason == WisprFlowProvider.incognitoMessage:
            return "⚠︎ Dictation is off: \(reason) — choose Parakeet under Transcription"
        case .wisprFlow:
            return "⚠︎ Dictation is slow: live stream unavailable (\(reason))\(Self.hint(for: reason))"
        case .parakeet:
            return "⚠︎ Parakeet is failing: \(reason)"
        }
    }

    private static func hint(for reason: String) -> String {
        guard reason == TranscriberError.noBasetenKey.userMessage else { return "" }
        return " — put Wispr's key in Application Support/VoiceOperator/baseten-key"
    }

    /// One log line per transition, so the runtime log shows exactly when the
    /// path changed and why.
    var logLine: String {
        switch self {
        case .unverified: return "stream health: unverified"
        case .streaming:  return "stream health: streaming — dictation is on the fast path"
        case .degraded(let reason, .parakeet):
            return "stream health: WARNING degraded (\(reason)) — Parakeet dictations are failing"
        case .degraded(let reason, .wisprFlow):
            return "stream health: WARNING degraded (\(reason)) — dictation is falling back to raw /llm/asr and will be slow and unformatted"
        }
    }
}
