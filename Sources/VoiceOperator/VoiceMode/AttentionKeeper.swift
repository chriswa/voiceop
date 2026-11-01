import Foundation

/// A hands-free client's attention to the user (`HandsFreeEngine.Attention`),
/// kept on the client's side, where hands-free's protocol puts it: hands-free
/// only listens the way it is told, and reports what this needs to decide.
///
/// - **Engaged** — no trigger word needed — on `engage()`: as hands-free comes
///   on, when the user speaks to the client, when its reply starts.
/// - **Lapsed** once nobody has spoken on the source for `engagedMs`
///   (hands-free's `quiet`): the user may not know, so speech without the
///   trigger word gets the alarm. After `alarmLimit` alarms the client stops
///   sounding them: attention is dismissed.
/// - **Dismissed** on `dismiss()`: the user ended it themselves ("stop
///   listening") and knows, so no alarm at all.
///
/// The Swift twin of Spaceterm's `src/server/hands-free-attention.ts`.
@MainActor
final class AttentionKeeper {
    typealias Attention = HandsFreeEngine.Attention

    struct Deps {
        /// Tell hands-free (`attention` on the protocol).
        var send: (_ attention: Attention, _ closesAt: Double?) -> Void
        /// Run `block` after `ms`; the closure returned cancels it.
        var after: (_ ms: Double, _ block: @escaping @MainActor () -> Void) -> () -> Void
        /// Wall clock, ms since 1970: what hands-free's `closesAt` is in.
        var now: () -> Double = { Date().timeIntervalSince1970 * 1000 }
    }

    /// How long attention stays engaged through quiet. Hands-free suggests one with its `session`.
    var engagedMs: Double = 15_000
    /// Alarms sounded after attention lapses before it is dismissed, quietly.
    var alarmLimit = 3

    private(set) var attention: Attention = .lapsed
    private var quiet = false
    private var closesAt: Double?
    private var cancelLapse: (() -> Void)?
    private var alarms = 0
    private let deps: Deps

    init(deps: Deps) { self.deps = deps }

    /// No trigger word needed, until it lapses.
    func engage() {
        attention = .engaged
        alarms = 0
        schedule()
    }

    /// The user ended it: the trigger word from here, and no alarm.
    func dismiss() { set(.dismissed) }

    /// Hands-free's `state`: whether anyone is speaking on the source.
    func see(quiet: Bool) {
        guard quiet != self.quiet else { return }
        self.quiet = quiet
        if attention == .engaged { schedule() }
    }

    /// Say it again, as it stands: hands-free may have lost it (a stream resumed).
    func restate() {
        if attention == .engaged { schedule() } else { deps.send(attention, nil) }
    }

    /// Hands-free sounded the alarm (its `notWakeWord` cue).
    func alarmed() {
        guard attention == .lapsed else { return }
        alarms += 1
        if alarms >= alarmLimit { set(.dismissed) }
    }

    /// Hands-free went off: nothing to keep.
    func reset() {
        stopTimer()
        attention = .lapsed
        quiet = false
        alarms = 0
    }

    private func set(_ next: Attention) {
        stopTimer()
        attention = next
        alarms = 0
        deps.send(next, nil)
    }

    /// Engaged: held while anyone speaks, and timed from when they stop.
    private func schedule() {
        stopTimer()
        if quiet {
            let at = deps.now() + engagedMs
            closesAt = at
            cancelLapse = deps.after(engagedMs) { [weak self] in
                guard let self, self.attention == .engaged, self.closesAt == at else { return }
                self.set(.lapsed)
            }
        }
        deps.send(.engaged, closesAt)
    }

    private func stopTimer() {
        cancelLapse?()
        cancelLapse = nil
        closesAt = nil
    }
}
