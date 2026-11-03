import Foundation

/// Service mode (`--service --home <dir>`): the speech engine alone, headless,
/// for another program to run as its own private instance beside the app
/// (vibeagame does). DESIGN.md "Service mode".
///
/// Read once, from the arguments, before anything else touches a path: every
/// path that would be under `~/Library/Application Support/VoiceOperator` (and
/// the log) is under `home` instead, and Kokoro runs on its own port as a
/// child process. Without these flags nothing here changes anything.
enum ServiceMode {
    /// `--home <dir>`: where everything is written. Also accepted without
    /// `--service`, so a debug client (`--hands-free-test`) can talk to a
    /// service's socket.
    nonisolated(unsafe) private(set) static var home: URL?
    /// `--service`: run headless (`ServiceCoordinator`) instead of the menu-bar app.
    nonisolated(unsafe) private(set) static var isService = false
    /// `--kokoro-port <n>`: the service's own Kokoro server. Never the app's 56841.
    nonisolated(unsafe) private(set) static var kokoroPort = 56851

    static let defaultKokoroPort = 56851

    /// Parse the flags. Returns an error message for bad ones.
    static func configure(_ arguments: [String]) -> String? {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        isService = arguments.contains("--service")
        if let dir = value("--home") {
            let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            catch { return "cannot create \(url.path): \(error.localizedDescription)" }
            home = url
        } else if arguments.contains("--home") {
            return "--home needs a directory"
        }
        if let port = value("--kokoro-port") {
            guard let n = Int(port), n > 0, n < 65536, n != 56841 else { return "--kokoro-port must be a port other than 56841" }
            kokoroPort = n
        }
        if isService, home == nil { return "--service needs --home <dir>" }
        return nil
    }
}
