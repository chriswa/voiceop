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

## Dictation transcription paths

`WisprFlowTranscriber` (the `AudioArbiter` default) transcribes over Wispr's
primary **gRPC** path (`flow_api.v1.TranscriptionService` on Baseten), which
returns **formatted** text with the user's dictionary — see DESIGN.md Milestone C
and `proto/flow_api_v1.proto`.

**Use `TranscribeStream`, not `Transcribe`.** The unary RPC is Wispr's *fallback*;
its primary is the duplex stream, opened on key-down and fed opus packets while
the user is still speaking (`FlowSession`, driven by `AudioArbiter.pumpAudio`), so
only the tail remains at key-up. Do not "simplify" this back to a single unary
call — that was the old design and it cost 5–10 s per dictation. The connection is
process-wide and keepalive'd (`FlowChannel`); never build a channel per call.
Every dictation logs one `trace …` line with the full phase timeline.

Client is **grpc-swift 1.x** (not 2.x) so the app
can target macOS 13 / universal. It needs Wispr's Baseten `Api-Key`, read at
runtime from `$VOICEOP_BASETEN_KEY` or
`~/Library/Application Support/VoiceOperator/baseten-key` (**never commit it**).
Without the key, it falls back to `WisprTranscriber` (raw `/llm/asr`). Regenerate
the gRPC/protobuf Swift with `scripts/gen-proto.sh`. Live-test either path with
`--flow-grpc-test` / `--asr-test`.

TTS base URL / Access headers: `$VOICEOP_KOKORO_URL` or
`~/Library/Application Support/VoiceOperator/config.json` (see `Config.swift`).
**Never commit** Cloudflare Access secrets.

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

### Never kill the process while the user may be dictating

**Do not `kill`, `pkill`, or `killall` Voice Operator, and do not restart it any
other way than through `make-app.sh` / `restart-app.sh`.** A restart mid-dictation
throws away what the user was saying, and they have to reconstruct it from
memory — that costs them far more than the wait costs you. The cooperative
restart exists so the *app* decides when it is safe: it finishes the dictation in
flight, pastes it, plays a "restarting" cue, and relaunches.

- If the script prints `waiting: the user is dictating…`, wait with it. It polls
  until the paste has happened (up to 10 minutes) and then continues on its own.
- If it times out (exit 3), the request is still pending inside the app and will
  fire when the dictation ends. Tell the user; do not force.
- `--force` (SIGTERM) is only for an app that is hung or too old to have the
  endpoint (exit 2). It loses any dictation in flight. Use it only when the user
  has said the app is stuck, or the script itself says the running instance
  predates the endpoint.
- To check state without restarting:
  ```bash
  curl -s "127.0.0.1:$(plutil -extract port raw -o - "$HOME/Library/Application Support/VoiceOperator/speech-service.json")/v1/status"
  # → {"version":"0.1.NN","status":"idle","dictating":false,"restart":"none",...}
  ```

Every build gets its own version number (`MAJOR.MINOR` from `Resources/Info.plist`,
patch from the untracked `.build-number` counter), shown in the menu just above
**Restart Voice Operator**, logged at launch, and returned by `/v1/status`. It
changing is the proof the restart picked up your build; a pid change alone is
not (a process keeps running a binary that was deleted out from under it).
Release versions are allocated from the same counter by
`./scripts/bump-version.sh` — see `docs/RELEASING.md`.

`swift test` runs the unit tests. Notarized universal releases:
`docs/RELEASING.md` / `./scripts/make-release.sh`.

## Debugging

- Runtime log: `~/Library/Logs/VoiceOperator.log` (append-only, written by
  `Sources/VoiceOperator/Core/Log.swift`; also mirrored to stderr).
- Check what's running with `curl …/v1/status` (see Building above) or
  `ps aux | grep VoiceOperator` — confirm it's the bundle binary and the version
  you just built. Restart only via `make-app.sh` / `restart-app.sh`, never `kill`.
