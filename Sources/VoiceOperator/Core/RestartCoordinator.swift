import Foundation

/// The one place a restart is decided. Anyone who wants the app restarted — the
/// menu item, or a build script over the loopback API — *asks* here, and the
/// restart happens at the first moment the user is not mid-dictation.
///
/// Why the app decides rather than the caller: a build script that checks "is a
/// dictation in flight?" and then kills the process has a window between the two
/// in which the user can press the trigger key, and a dictation lost that way
/// costs them not just the words but their train of thought. Inside the app the
/// check and the commit happen in one main-actor turn, and every path that starts
/// a dictation runs on that same actor, so nothing can slip between them.
///
/// "Busy" is `AudioArbiter.isDictating`, which spans key-down → transcription →
/// paste → the closing cue. Speech playback does not count: a half-spoken
/// sentence is re-queueable by whoever asked for it, and waiting on a long
/// read-aloud would stall every rebuild.
@MainActor
final class RestartCoordinator {
    enum Source: String { case menu, http }

    enum State: Equatable {
        /// Nothing asked for a restart.
        case none
        /// A restart was asked for while a dictation was in flight; it fires when
        /// that dictation (and any that starts before we get to it) has finished.
        case pending(source: Source, since: Date)
        /// The cue is playing; termination follows in a fraction of a second.
        case restarting

        /// The name the `/v1/status` endpoint reports.
        var wireName: String {
            switch self {
            case .none: return "none"
            case .pending: return "pending"
            case .restarting: return "restarting"
            }
        }
    }

    private(set) var state: State = .none

    /// Time to let the cue finish before the process goes away, on top of the
    /// cue's own duration.
    static let cueMargin: TimeInterval = 0.15

    private let isBusy: () -> Bool
    private let playCue: () -> TimeInterval
    private let perform: () -> Void
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void

    /// - Parameters:
    ///   - isBusy: true while a dictation is in flight (see `AudioArbiter.isDictating`).
    ///   - playCue: start the restart cue; returns how long it plays.
    ///   - perform: actually restart (see `Relauncher`).
    ///   - schedule: run a closure after a delay; injectable so tests run synchronously.
    init(isBusy: @escaping () -> Bool,
         playCue: @escaping () -> TimeInterval = { SoundEffect.restarting.play(); return SoundEffect.restarting.duration },
         perform: @escaping () -> Void = { Relauncher.restartAfterTermination() },
         schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { work() }
         }) {
        self.isBusy = isBusy
        self.playCue = playCue
        self.perform = perform
        self.schedule = schedule
    }

    /// Ask for a restart. Restarts immediately when idle; otherwise records the
    /// request and returns `.pending`. Repeat requests are harmless: a pending or
    /// in-progress restart is left alone and its state returned.
    @discardableResult
    func request(source: Source) -> State {
        switch state {
        case .restarting:
            return state
        case .pending:
            Log.log("restart: already pending; \(source.rawValue) request noted")
            return state
        case .none:
            state = .pending(source: source, since: Date())
            Log.log("restart: requested (\(source.rawValue))\(isBusy() ? " — deferred until the current dictation is pasted" : "")")
            attempt()
            return state
        }
    }

    /// Fire a pending restart if the app has become idle. Call whenever a
    /// dictation ends; a no-op when nothing is pending or a dictation is still
    /// in flight.
    func attempt() {
        guard case .pending(let source, let since) = state, !isBusy() else { return }
        state = .restarting
        let waited = Date().timeIntervalSince(since)
        Log.log("restart: idle — restarting now (\(source.rawValue), waited \(String(format: "%.1f", waited))s)")
        let cueDuration = playCue()
        schedule(cueDuration + Self.cueMargin) { [weak self] in
            guard let self, case .restarting = self.state else { return }
            // The user may have pressed the trigger key while the cue was playing.
            // A dictation is worth more than a prompt restart: step back to pending
            // and let its end bring us here again.
            if self.isBusy() {
                Log.log("restart: a dictation started during the cue — waiting for it")
                self.state = .pending(source: source, since: since)
                return
            }
            self.perform()
        }
    }
}
