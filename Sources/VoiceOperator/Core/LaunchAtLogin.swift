import ServiceManagement

/// Thin wrapper over SMAppService for the "Open at Login" toggle (macOS 13+).
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Toggle registration; returns the effective state afterwards.
    @discardableResult
    static func toggle() -> Bool {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.log("launch-at-login toggle failed: \(error)")
        }
        return isEnabled
    }
}
