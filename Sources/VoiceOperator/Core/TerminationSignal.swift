import AppKit

/// Turns `kill <pid>` into an ordinary quit.
///
/// Left to the default, SIGTERM ends the process on the spot: `applicationWillTerminate`
/// never runs, the dictation output-mute is never restored, and the loopback
/// discovery file is left pointing at a dead pid. Routing the signal through
/// `NSApp.terminate` gives every path out of the process the same clean-up.
///
/// SIGTERM still means *terminate now*. It does not wait for a dictation to end —
/// that is what `RestartCoordinator` and the `/v1/restart` endpoint are for — so
/// `kill` remains a reliable way to stop an app that is no longer responding.
@MainActor
enum TerminationSignal {
    private static var source: DispatchSourceSignal?

    static func routeSIGTERMToGracefulQuit() {
        // The default disposition must be replaced before the dispatch source can
        // see the signal; otherwise the kernel's default action still applies.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            Log.log("SIGTERM received — quitting")
            NSApp.terminate(nil)
        }
        source.resume()
        self.source = source
    }
}
