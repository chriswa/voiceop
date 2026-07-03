import Foundation
import ServiceManagement

/// Thin wrapper over SMAppService for launch-at-login (macOS 13+).
enum LaunchAtLogin {
    private static let configuredKey = "vo.didConfigureLoginItem"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ on: Bool) {
        do {
            if on, !isEnabled { try SMAppService.mainApp.register() }
            else if !on, isEnabled { try SMAppService.mainApp.unregister() }
        } catch {
            Log.log("launch-at-login setEnabled(\(on)) failed: \(error)")
        }
    }

    /// Toggle registration; returns the effective state afterwards. Also marks
    /// login-at-launch as user-configured so we won't override the choice.
    @discardableResult
    static func toggle() -> Bool {
        UserDefaults.standard.set(true, forKey: configuredKey)
        setEnabled(!isEnabled)
        return isEnabled
    }

    /// Enable launch-at-login by default the first time the app runs; thereafter
    /// leave it to the user's toggle (we only auto-configure once, so turning it
    /// off sticks).
    static func enableByDefaultOnce() {
        guard !UserDefaults.standard.bool(forKey: configuredKey) else { return }
        UserDefaults.standard.set(true, forKey: configuredKey)
        setEnabled(true)
        Log.log("launch-at-login: enabled by default on first run (enabled=\(isEnabled))")
    }
}
