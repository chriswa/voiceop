import AppKit

/// Dev builds: if launched from outside /Applications (e.g. `build/`), copy this
/// bundle to /Applications, quit any copy already running, launch the
/// /Applications copy and exit.
///
/// On macOS 27 the menu bar can't attribute status items from apps outside
/// /Applications, so menu-bar managers that hide icons (Ice 2) hide ours too,
/// whatever section it's assigned to. Running from /Applications avoids that
/// without changing how the app is built or launched.
enum ApplicationsRelocator {
    private static let sourceKey = "ApplicationsRelocator.sourceBundlePath"

    /// The bundle a restart should launch: the dev build this copy was installed
    /// from, so a restart after a rebuild picks up the new build instead of
    /// relaunching the stale /Applications copy.
    static var relaunchBundleURL: URL {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: sourceKey),
           path != Bundle.main.bundleURL.resolvingSymlinksInPath().path,
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        #endif
        return Bundle.main.bundleURL
    }

    static func relocateIfNeeded() {
        #if DEBUG
        let source = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard source.pathExtension == "app" else { return }  // bare `swift run`
        let dest = URL(fileURLWithPath: "/Applications").appendingPathComponent(source.lastPathComponent)
        guard source.path != dest.path else { return }

        // Quit first, even if the copy then fails (no write access to /Applications
        // without admin rights): a fresh build should replace the old copy either way.
        quitOtherInstances()
        do {
            try install(source, at: dest)
        } catch {
            Log.log("relocate: couldn't copy to \(dest.path), running from \(source.path): \(error)")
            return
        }
        UserDefaults.standard.set(source.path, forKey: sourceKey)

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [dest.path, "--args"] + CommandLine.arguments.dropFirst()
        do {
            try open.run()
            open.waitUntilExit()
        } catch {
            Log.log("relocate: couldn't launch \(dest.path), running from \(source.path): \(error)")
            return
        }
        guard open.terminationStatus == 0 else {
            Log.log("relocate: `open \(dest.path)` exited \(open.terminationStatus), running from \(source.path)")
            return
        }
        Log.log("relocate: launched \(dest.path); exiting \(source.path)")
        exit(0)
        #endif
    }

    private static func quitOtherInstances() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me }
        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    /// Copies via a sibling temp bundle so a failed copy never leaves a half-written app.
    private static func install(_ source: URL, at dest: URL) throws {
        let fm = FileManager.default
        let staging = dest.deletingLastPathComponent()
            .appendingPathComponent(".\(dest.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: staging)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = [source.path, staging.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            try? fm.removeItem(at: staging)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: staging.path])
        }
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: dest)
        }
    }
}
