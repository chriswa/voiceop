import Foundation

/// Which insertion technique a finished transcript uses. Persisted in
/// `UserDefaults` alongside the other menu preferences so the choice survives
/// relaunches.
enum PastePreferences {
    private static let techniqueKey = "vo.pasteTechnique"

    /// Defaults to `.clipboard`. `.keystrokes` exists for apps that mishandle a
    /// real paste — Claude Code drops the leading part of pasted text often
    /// enough to be worth a switch that sidesteps the pasteboard entirely.
    static var technique: PasteTechnique {
        get { PasteTechnique(rawValue: UserDefaults.standard.string(forKey: techniqueKey) ?? "") ?? .clipboard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: techniqueKey) }
    }
}
