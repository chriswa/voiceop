import Foundation

/// Which build is actually running, as one log line.
///
/// `make-app.sh` deletes and rewrites the bundle, but a *running* Voice Operator
/// goes on executing the binary that was deleted out from under it. An instance
/// can therefore be weeks behind the source tree while every build reports
/// success — deleted features still working, new ones never appearing.
///
/// So every launch states its identity: version, source commit, when the binary
/// was built, and the bundle it was launched from. "Is the app I am using the app
/// I just built?" is a `grep launching` away.
enum BuildInfo {
    /// `VOSourceCommit` is stamped into the *bundle's copy* of Info.plist by the
    /// build scripts (never the checked-in file), so it is absent for `swift run`.
    static var summary: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let commit = info?["VOSourceCommit"] as? String ?? "no commit stamp"
        return "v\(version) (\(build)), \(commit), built \(builtAt), running from \(runningFrom)"
    }

    /// The bundle we were launched from — or the bare executable under `swift run`,
    /// which is exactly the distinction that matters when two of them are around.
    static var runningFrom: String {
        let bundle = Bundle.main.bundleURL
        return bundle.pathExtension == "app" ? bundle.path : (Bundle.main.executablePath ?? bundle.path)
    }

    /// Modification time of the running executable: the moment it was built.
    private static var builtAt: String {
        guard let path = Bundle.main.executablePath,
              let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return "unknown" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
