import Foundation

/// Which build is actually running — as one log line at launch, and as one line
/// in the menu.
///
/// `make-app.sh` deletes and rewrites the bundle, but a *running* Voice Operator
/// goes on executing the binary that was deleted out from under it: the process
/// holds the deleted inode open. An instance can therefore be weeks behind the
/// source tree while every build reports success — deleted features still
/// working, new ones never appearing.
///
/// So every build gets its own version number (`scripts/lib.sh allocate_version`),
/// including two builds of identical source, and the app states its identity in
/// both places. "Did the restart pick up what I just built?" is then a glance at
/// the menu: the version has to have changed.
enum BuildInfo {
    /// One line for the menu: the version, and the source commit it was built
    /// from. Both are stamped into the *bundle's* Info.plist by the build scripts
    /// (never the checked-in file), so under `swift run` there is no stamp to read
    /// and this says so rather than inventing a number.
    static var menuLabel: String { "Version \(version) — \(commit)" }

    /// The same identity plus where this binary came from and when, for the log —
    /// which is the place the *bundle path* matters, because two of them being
    /// around is exactly how a stale instance goes unnoticed.
    static var summary: String {
        "v\(version) (\(build)), \(commit), built \(builtAt), running from \(runningFrom)"
    }

    /// `MAJOR.MINOR.PATCH`, where PATCH is the build counter — see
    /// `allocate_version` in `scripts/lib.sh`.
    static var version: String { plist("CFBundleShortVersionString") ?? "?" }
    /// The build counter on its own, as `CFBundleVersion`.
    static var build: String { plist("CFBundleVersion") ?? "?" }
    /// `VOSourceCommit`, stamped by the build scripts; absent for `swift run`.
    static var commit: String { plist("VOSourceCommit") ?? "no commit stamp" }

    /// The bundle we were launched from — or the bare executable under `swift run`,
    /// which is exactly the distinction that matters when two of them are around.
    static var runningFrom: String {
        let bundle = Bundle.main.bundleURL
        return bundle.pathExtension == "app" ? bundle.path : (Bundle.main.executablePath ?? bundle.path)
    }

    private static func plist(_ key: String) -> String? {
        Bundle.main.infoDictionary?[key] as? String
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
