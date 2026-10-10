import AppKit

/// Restarts the app: spawns a small detached `/bin/sh` helper that waits for our
/// PID to exit (up to 60 s), then relaunches the bundle and exits itself. We then terminate.
/// The helper survives our death (it's not killed by a graceful NSApp.terminate),
/// so the relaunch happens after we're fully gone — no port/tap/socket clashes.
enum Relauncher {
    static func restartAfterTermination() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundle = Bundle.main.bundleURL
        // Relaunch the .app via LaunchServices when bundled; otherwise re-exec the
        // bare binary (dev `swift run`).
        let relaunch = bundle.pathExtension == "app"
            ? "open \(shellQuote(bundle.path)) || log \"open failed (exit $?)\""
            : "\(shellQuote(Bundle.main.executablePath ?? bundle.path)) &"

        // Relaunch only once the PID is gone: `open` on a bundle whose instance is
        // still shutting down just activates that instance, which then exits, and
        // nothing comes back. The helper writes to the app's log, so a restart that
        // doesn't return says why.
        let log = shellQuote(Log.fileURL.path)
        let script = """
        log() { printf '[%s] relauncher: %s\\n' "$(date +%H:%M:%S)" "$1" >> \(log); }
        i=0
        while kill -0 \(pid) 2>/dev/null; do
            i=$((i + 1))
            if [ $i -ge 600 ]; then log "pid \(pid) still running after 60s; not relaunching"; exit 1; fi
            sleep 0.1
        done
        log "pid \(pid) exited after ~$((i / 10))s; relaunching"
        \(relaunch)
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        do {
            try task.run()
            Log.log("restart: relauncher spawned (waiting on pid \(pid)); terminating")
        } catch {
            Log.log("restart: failed to spawn relauncher: \(error)")
            return   // don't terminate if we couldn't arrange the relaunch
        }
        NSApp.terminate(nil)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
