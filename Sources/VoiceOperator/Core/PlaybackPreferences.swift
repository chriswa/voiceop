import Foundation

/// Uses the app's persistent preferences file, like the overlay and hotkey
/// settings. Kept separate from the lifetime of an individual speech job.
struct PlaybackPreferences {
    var defaults: UserDefaults = .standard
    private let key = "vo.playbackRate"

    var rate: Float {
        get {
            guard let number = defaults.object(forKey: key) as? NSNumber else { return 1 }
            return Self.validRate(number.floatValue)
        }
        nonmutating set { defaults.set(Self.validRate(newValue), forKey: key) }
    }

    static func validRate(_ rate: Float) -> Float {
        guard rate.isFinite else { return 1 }
        return min(5, max(0.5, (rate * 10).rounded() / 10))
    }

    /// One small arrow per 0.2× away from normal. A partial step at the 0.5×
    /// clamp still gets an arrow; negative counts point left.
    static func indicatorSteps(for rate: Float) -> Int {
        let delta = validRate(rate) - 1
        let count = Int(ceil(abs(delta) / 0.2 - 0.0001))
        return delta < 0 ? -count : count
    }
}
