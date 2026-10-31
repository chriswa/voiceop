import Foundation

/// How long the conversation window stays open once both sides are quiet,
/// picked from the menu's Hands-Free Listening submenu. The order here is the
/// submenu's.
enum ConversationTimeout: Int, CaseIterable {
    case s15 = 15, s30 = 30, m1 = 60, m2 = 120, m5 = 300

    var ms: Double { Double(rawValue) * 1000 }

    var title: String {
        rawValue < 60 ? "\(rawValue) Seconds" : rawValue == 60 ? "1 Minute" : "\(rawValue / 60) Minutes"
    }
}

/// Hands-free choices from the menu. Persisted in `UserDefaults`; read on any
/// thread — each engine reads the timeout every frame, so a change applies to
/// the window already open.
enum HandsFreePreferences {
    private static let conversationKey = "vo.handsFreeConversationSeconds"

    /// Defaults to `HandsFreeTuning.standard`'s 15 s.
    static var conversationTimeout: ConversationTimeout {
        get { ConversationTimeout(rawValue: UserDefaults.standard.integer(forKey: conversationKey)) ?? .s15 }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: conversationKey) }
    }
}
