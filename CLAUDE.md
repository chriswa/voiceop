# Voice Operator — agent notes

macOS menu-bar app (SwiftPM). Architecture and plans are in `DESIGN.md`.

## The Wispr Flow app is the ground truth — READ IT, don't guess

This app depends on Wispr Flow's **private, unversioned** HTTP API (STT) — no
public docs exist. The **only** reliable source of truth for how those endpoints
work is the Wispr Flow Electron app itself. Treat its bundle as the holy grail:
before touching any Wispr request/response shape, field name, encoding, or
endpoint, **read the real implementation** rather than probing the live API and
guessing from error messages.

```bash
# Extract the bundle (192 MB; the main bundle holds the STT client):
asar extract "/Applications/Wispr Flow.app/Contents/Resources/app.asar" /tmp/wispr-app
# It's minified — grep for the symbol, then read a character window around it:
grep -a -c "serializeFlowRequest" /tmp/wispr-app/.webpack/main/index.js
```

Key entry points in `.webpack/main/index.js`: `serializeFlowRequest` (the full
`/llm/asr_audio_chunks` flow-request body), `transcribeOpenAIAudio` /
`transcribeOpenAIAudioChunks` (the `/llm/asr*` calls), and the packet serializer
(`packet_duration`, `byte_encoding: "ascii85"`, `audio_encoding: "opus"`).
Black-box probing wastes real API calls, risks account rate-limits, and silently
gets encodings wrong (the server accepts a base64 string where it wants ascii85
and just decodes garbage). **Never experiment against these third-party APIs
without first confirming the exact behavior in the app bundle.** When you decode
something new, record it in `DESIGN.md` + `spike/` so it's never lost.

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
