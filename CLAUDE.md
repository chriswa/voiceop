# Voice Operator — agent notes

macOS menu-bar app (SwiftPM). Architecture and plans are in `DESIGN.md`.

## Building — `swift build` alone is NOT enough

The app the user actually runs is the bundle at `build/Voice Operator.app`.
`swift build` only compiles the bare SwiftPM binary; the running app and its
in-app "Restart Voice Operator" menu item use the bundle, so your change will
silently not take effect. After any code change intended for the running app:

```bash
./scripts/make-app.sh    # swift build + repackage + codesign the .app bundle
```

Then have the app restart — either the user clicks the menu-bar
**Restart Voice Operator** item, or kill the running `VoiceOperator` process and
`open "build/Voice Operator.app"`.

`swift test` runs the unit tests.

## Debugging

- Runtime log: `~/Library/Logs/VoiceOperator.log` (append-only, written by
  `Sources/VoiceOperator/Core/Log.swift`; also mirrored to stderr).
- Check what's running with `ps aux | grep VoiceOperator` — confirm it's the
  bundle binary, and restart it after rebuilding or your change isn't live.
