import AppKit
import Carbon.HIToolbox
import IOKit

/// Whether macOS **secure event input** is on, and which app is holding it.
///
/// An app that calls `EnableSecureEventInput` (Terminal's "Secure Keyboard
/// Entry", password fields, some remote-desktop clients) makes the window server
/// withhold key events from *every* event tap in the session — not just its own
/// window, and not just while it is frontmost. Our ⌘⌃ chord shortcuts are all
/// `keyDown` events, so they stop arriving entirely.
///
/// The Fn dictation trigger keeps working throughout, because it arrives as a
/// `flagsChanged` modifier event, and those are still delivered. Half the app
/// therefore carries on working perfectly while the other half goes dead — which
/// is why this is worth naming rather than leaving to be deduced.
///
/// Nothing can be done about it in code; the log and the menu say which app to go
/// and turn it off in.
enum SecureInput {
    static var isEnabled: Bool { IsSecureEventInputEnabled() }

    /// The app holding secure input, e.g. "Terminal". Nil when it is off, or when
    /// the holder is not a running GUI application we can name.
    static var holderName: String? {
        guard let pid = holderPID else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
    }

    /// One line naming the state, for the log and the menu.
    static var description: String {
        guard isEnabled else { return "off" }
        guard let holder = holderName else { return "ON (holder unknown)" }
        return "ON (held by \(holder))"
    }

    /// The window server records the holder on the console-user session in the IO
    /// registry; `IsSecureEventInputEnabled` alone says only that *someone* has it.
    private static var holderPID: pid_t? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let sessions = IORegistryEntryCreateCFProperty(
            root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [[String: Any]] else { return nil }
        // Via NSNumber: the registry value is a CFNumber, and a direct
        // `as? pid_t` (Int32) does not bridge it reliably.
        for session in sessions {
            if let pid = (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value { return pid }
        }
        return nil
    }
}
