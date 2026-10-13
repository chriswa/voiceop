import Foundation

/// Incognito mode: while it is on, nothing the user says or hears leaves this
/// Mac, and none of it is written to disk. Dictation still works through
/// Parakeet and speech through the local Kokoro; everything else that would
/// carry content off the machine or into a file refuses.
///
/// The guard is deliberately not one check at the top of the app. Every
/// network client and every content-bearing writer asks `check` itself, at the
/// lowest level it owns (the gRPC channel, the URL request, the file write), so
/// a new caller cannot reach the wire or the disk by forgetting to ask. The
/// higher-level checks that exist are for a clear error and an early exit, not
/// for safety. `IncognitoTests` holds every gate to this.
///
/// Persisted in `UserDefaults`, so a restart, or a crash, cannot quietly turn it
/// off. The flag holds no content.
enum Incognito {
    private static let key = "vo.incognito"

    /// UserDefaults is thread-safe, so this is read from any actor or queue.
    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// What wants to happen. The `String` names the thing, for the log and the
    /// error ("Wispr Flow", "dictation history").
    enum Activity: Equatable, Sendable, CustomStringConvertible {
        /// Content (audio, text) or the credentials that carry it sent to a
        /// service off this Mac.
        case network(String)
        /// Content written to a file that outlives the dictation or the speech.
        case persist(String)
        /// Content handed to Spaceterm: phone dictation and synthesis, wake-word
        /// clips, command dictations and dictation events on subscriber sockets.
        /// Spaceterm runs locally but relays to the phone, and what it keeps is
        /// not ours to promise — see `blocksSpaceterm`.
        case spaceterm(String)

        var description: String {
            switch self {
            case .network(let what): return "\(what) (leaves this Mac)"
            case .persist(let what): return "\(what) (writes to disk)"
            case .spaceterm(let what): return "\(what) (Spaceterm)"
            }
        }
    }

    /// Spaceterm is blocked as a policy choice, not because it is off-device by
    /// nature, so it has its own switch. Flip this to let incognito dictation
    /// reach Spaceterm again; every Spaceterm path already asks `.spaceterm`.
    static let blocksSpaceterm = true

    static func allows(_ activity: Activity) -> Bool {
        guard isOn else { return true }
        if case .spaceterm = activity { return !blocksSpaceterm }
        return false
    }

    /// Throw `Blocked` (and say so in the log) when incognito forbids `activity`.
    static func check(_ activity: Activity) throws {
        if let blocked = refusal(activity) { throw blocked }
    }

    /// `check` for a caller that answers rather than throws: the refusal, logged,
    /// or nil when `activity` may go ahead.
    static func refusal(_ activity: Activity) -> Blocked? {
        guard !allows(activity) else { return nil }
        Log.log("incognito: blocked \(activity)")
        return Blocked(activity: activity)
    }

    struct Blocked: Error, Equatable, CustomStringConvertible {
        let activity: Activity
        var description: String {
            switch activity {
            case .network(let what), .persist(let what), .spaceterm(let what):
                return "incognito mode blocks \(what)"
            }
        }
    }
}
