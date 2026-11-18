import Foundation

/// Whether dictation is working: Parakeet loaded and the last dictation
/// transcribed, or something failed. A failed load (a download that never
/// finished, a CoreML compile error) would otherwise only show as dictations
/// that paste nothing, so this drives a menu-bar warning, an icon badge and the
/// `/v1/status` payload.
enum StreamHealth: Equatable, Sendable {
    /// Nothing has exercised the provider yet this session. Shows nothing.
    case unverified
    /// The last dictation transcribed.
    case streaming
    /// The model failed to load or the last dictation failed. `reason` is the
    /// short user message from `TranscriptionFailure.message(for:)`.
    case degraded(reason: String)

    var isDegraded: Bool { if case .degraded = self { return true } else { return false } }

    var reason: String? { if case .degraded(let r) = self { return r } else { return nil } }

    /// The value reported by `/v1/status`.
    var wireName: String {
        switch self {
        case .unverified: return "unverified"
        case .streaming:  return "streaming"
        case .degraded:   return "degraded"
        }
    }

    /// The persistent warning line at the top of the menu, or nil to hide it.
    var menuWarning: String? {
        guard case .degraded(let reason) = self else { return nil }
        return "⚠︎ Parakeet is failing: \(reason)"
    }

    /// One log line per transition, so the runtime log shows exactly when it
    /// changed and why.
    var logLine: String {
        switch self {
        case .unverified: return "stream health: unverified"
        case .streaming:  return "stream health: ok"
        case .degraded(let reason):
            return "stream health: WARNING degraded (\(reason)) — Parakeet dictations are failing"
        }
    }
}
