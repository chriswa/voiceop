import Foundation

/// Where the word-highlight bar sits during TTS playback. ⌘⌃/ steps through the
/// cases in declaration order and wraps, so the order here *is* the cycle.
enum OverlayPlacement: String, CaseIterable {
    case bottom, lowerMiddle, middle, upperMiddle, top, hidden

    var next: OverlayPlacement {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    var title: String {
        switch self {
        case .bottom:      return "Bottom"
        case .lowerMiddle: return "Lower Middle"
        case .middle:      return "Middle"
        case .upperMiddle: return "Upper Middle"
        case .top:         return "Top"
        case .hidden:      return "Hidden"
        }
    }
}

/// User-facing choices about the on-screen overlays. Persisted in `UserDefaults`
/// (same store as `HotkeyPreferences` / `LaunchAtLogin`) so the choice survives
/// relaunches.
enum OverlayPreferences {
    private static let placementKey = "vo.wordOverlayPlacement"
    /// The on/off switch this replaced. Read only to carry an old "off" over as
    /// `.hidden`, so nobody who turned the overlay off finds it back on.
    private static let legacyEnabledKey = "vo.wordOverlayEnabled"

    /// Where the word-highlight bar is shown. Defaults to the bottom.
    static var placement: OverlayPlacement {
        get {
            if let raw = UserDefaults.standard.string(forKey: placementKey),
               let placement = OverlayPlacement(rawValue: raw) { return placement }
            return UserDefaults.standard.object(forKey: legacyEnabledKey) as? Bool == false ? .hidden : .bottom
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: placementKey) }
    }
}
