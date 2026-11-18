# Voice Operator — agent notes

macOS menu-bar app (SwiftPM). Architecture and plans are in `DESIGN.md`.

## Dictation transcription

Everything is on this Mac. Dictation goes through `TranscriptionProviders.primary`:
**Parakeet** (FluidAudio, CoreML; raw — no fix-up, no custom words), wrapped in
`CleanedUpProvider` when clean-up is on. The arbiter, hands-free and phone
dictation know only `TranscriptionProvider` / `TranscriptionLeg`: a session opens
on key-down and is fed audio while the user speaks, so only the tail remains at
key-up. If the session never opened, the leg transcribes the recorded clip; a
failed commit is reported, not retried. Every dictation logs one `trace …` line
with the full phase timeline. Live-test with `--provider-test [text]`.

**Clean Up Transcripts** (a top-level menu checkbox) runs Parakeet's text through Fluid-1 Mini on a
local llama.cpp launchd agent (`CleanedUpProvider`, `CleanupServer`); a failure pastes the
raw text. See DESIGN.md "Dictation clean-up". The prompt
(`Resources/dictation-cleanup.md`) is clean-room: **never paste FluidVoice's own prompt
text into this public repo.** Live-test with `--cleanup-test [text]`.

**Failures are loud** (`StreamHealth`): when Parakeet fails to load or a
dictation fails, the menu carries a `⚠︎ Parakeet is failing…` line naming the
reason, the icon wears an amber dot even at idle, the log gets a
`stream health: WARNING degraded` line, `/v1/status` reports
`"stream":"degraded"` + `stream_reason`, and `restart-app.sh` prints a WARNING
after every restart. The model is loaded at launch, so a broken Mac shows this
before the first dictation. Fix the cause rather than the symptom.

**Kokoro server (`kokoro/`).** The default TTS backend is a Python service in
`kokoro/`, installed and managed by Voice Operator (Text to Speech menu). Read
`kokoro/CLAUDE.md` before touching it; never `kill` it — use the menu's Restart.

## Building — `swift build` alone is NOT enough

The app the user actually runs is the bundle at `build/Voice Operator.app`.
`swift build` only compiles the bare SwiftPM binary; the running app and its
in-app "Restart Voice Operator" menu item use the bundle, so your change will
silently not take effect. After any code change intended for the running app:

```bash
./scripts/make-app.sh    # swift build + repackage + codesign + cooperative restart
```

That one command is the whole workflow. Its last step asks the running app to
restart itself over the loopback API (`POST /v1/restart`, see
`scripts/restart-app.sh`) and then waits for the new instance to report the
version it just built, printing `restarted: v0.1.NN` on success. That line is
your proof the change is live; if the script exits non-zero, the change is
**not** live — read its message.

### Never kill the process while the user may be dictating or listening

**Do not `kill`, `pkill`, or `killall` Voice Operator, and do not restart it any
other way than through `make-app.sh` / `restart-app.sh`.** A restart mid-dictation
throws away what the user was saying, and they have to reconstruct it from
memory — that costs them far more than the wait costs you. A restart mid-TTS cuts
off what they were listening to. The cooperative restart exists so the *app*
decides when it is safe: it finishes the dictation in flight, pastes it, waits for
any speech to finish, plays a "restarting" cue, and relaunches.

Anything else that can stop audio the user may be hearing — an output-device
change, a test that reconfigures CoreAudio — waits until you have established
they are not listening, and waits longer when you cannot tell. If you need to
watch such an interruption happen, announce it over TTS, start a sample TTS of
your own, and interrupt that rather than whatever they were playing.

- If the script prints `waiting: the user is dictating…` or `waiting: the user is
  listening to speech…`, wait with it. It polls until the app is idle (up to 10
  minutes) and then continues on its own.
- If it times out (exit 3), the request is still pending inside the app and will
  fire when the dictation ends. Tell the user; do not force.
- `--force` (SIGTERM) is only for an app that is hung or too old to have the
  endpoint (exit 2). It loses any dictation in flight. Use it only when the user
  has said the app is stuck, or the script itself says the running instance
  predates the endpoint.
- To check state without restarting:
  ```bash
  curl -s "127.0.0.1:$(plutil -extract port raw -o - "$HOME/Library/Application Support/VoiceOperator/speech-service.json")/v1/status"
  # → {"version":"0.1.NN","status":"idle","dictating":false,"speaking":false,"restart":"none","stream":"streaming",...}
  #   A restart waits for both "dictating" and "speaking" to be false.
  #   "stream" is "degraded" (+ "stream_reason") when dictation is on the slow path.
  ```

Every build gets its own version number (`MAJOR.MINOR` from `Resources/Info.plist`,
patch from the untracked `.build-number` counter), shown in the menu just above
**Restart Voice Operator**, logged at launch, and returned by `/v1/status`. It
changing is the proof the restart picked up your build; a pid change alone is
not (a process keeps running a binary that was deleted out from under it).
Release versions are allocated from the same counter by
`./scripts/bump-version.sh` — see `docs/RELEASING.md`.

`swift test` runs the unit tests. Notarized arm64 releases:
`docs/RELEASING.md` / `./scripts/make-release.sh`.

## Debugging

- Runtime log: `~/Library/Logs/VoiceOperator.log` (append-only, written by
  `Sources/VoiceOperator/Core/Log.swift`; also mirrored to stderr).
- Check what's running with `curl …/v1/status` (see Building above) or
  `ps aux | grep VoiceOperator` — confirm it's the bundle binary and the version
  you just built. Restart only via `make-app.sh` / `restart-app.sh`, never `kill`.
