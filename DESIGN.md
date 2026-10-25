# Voice Operator — Design

## Current scope (2026-07-27)

Voice Operator is now deliberately a small dictation and local speech service.
It no longer watches Claude transcripts, summarizes agent work, assigns names or
voices to agents, or pushes agent-update state to Spaceterm.

### Local speech API

At launch the app binds a loopback TCP listener on a kernel-assigned ephemeral
port and atomically writes `~/Library/Application Support/VoiceOperator/speech-service.json`:

```json
{"version":2,"port":58432,"pid":12345}
```

There is no bearer token: this is a same-user, loopback service. Clients read
the discovery file (and re-read it after a connection failure). The file is
removed when the app quits, so a present file whose `pid` is alive means a
reachable instance. `version` is the API generation: 2 added `/v1/status` and
`/v1/restart`; 5 added `/v1/transcriptions` (status reports
`"remote_transcription": true` for feature detection); 7 added `parts` on
`POST /v1/speech`; 17 added speech on a device (`client` and `device` on
`POST /v1/speech`).

| Method | Path | Meaning |
| --- | --- | --- |
| `POST` | `/v1/speech` | Queue `{text, voice?}` — or `{parts: [{text, voice?}, …]}` for one job in several voices — and return `202` + job id. With `client` and `device` it is spoken on that device instead (see "Speech on a device"): `404 unknown_device` when none by that name is connected, `403 incognito` in incognito mode. `400` for a body with both or neither of `text`/`parts`, an empty `parts` (`parts_empty`), or a part with blank text (`part_text_required` + `index`); `422 text_too_long` past 50 000 scalars of the joined text; `503 speech_muted`. |
| `GET` | `/v1/speech/{id}?wait=0..30[&since=N]` | Inspect or long-poll a job. Pending is `202`; complete is `200`; a dictation barge-in is `409`; cancellation/mute flush is `410`; synthesis failure is `500`. |
| `DELETE` | `/v1/speech/{id}` | Halt immediately if audible, otherwise retract it. |
| `GET` | `/v1/voices` | Return the currently available external Kokoro voices. |
| `GET` | `/v1/status` | `{version, build, commit, pid, status, dictating, restart}` — which build is running and what it is doing. `status` is the menu-bar state (`idle`, `listening`, `transcribing`, `speaking`, …); `restart` is `none`, `pending`, or `restarting`. |
| `POST` | `/v1/restart` | Ask the app to relaunch itself. `200 {"restart":"restarting"}` when idle; `202 {"restart":"pending","reason":"dictating"}` when a dictation is in flight — it fires once that dictation has been pasted. Idempotent. |
| `POST` | `/v1/transcriptions` | Open a remote dictation. Optional body `{"sample_rate": N}` (default 16000; any rate 8000–192000 is resampled to 16 kHz). Opens the Flow stream immediately, as key-down does. `201 {"id"}`; `400` bad body; `422` unsupported rate. |
| `POST` | `/v1/transcriptions/{id}/audio` | Raw s16le mono PCM at the session's rate (`application/octet-stream`, chunks may split samples). Encoded to opus and streamed up as it arrives. `204`; `404` unknown id; `409` already finished. |
| `POST` | `/v1/transcriptions/{id}/finish` | Commit and wait for the formatted transcript: `200 {"text"}` (`""` for no audio). `502`/`503` `{"error":"transcription_failed","detail"}` on upstream failure (503 = signed out); `404`/`409` as above. |
| `DELETE` | `/v1/transcriptions/{id}` | Discard a session in any state. `204`; `404` unknown id. |

Remote transcription (`RemoteTranscriptionManager`) exists for the Spaceterm
phone client, relayed by the Spaceterm server: browsers cannot speak Wispr's
gRPC, and Supabase's rotating refresh tokens mean only one process may own the
Wispr session. Each session takes the same path as a local dictation — a
`FlowSession` on the shared `FlowChannel` with the user's dictionary, falling
back to raw `/llm/asr` on the whole clip when there is no Baseten key or the
stream fails — but touches none of the local dictation machinery (no paste,
cues, overlay or muting), so it can run alongside one. Each logs one
`trace remote#N` line. Sessions idle over 120 s are cancelled, finished ones are
forgotten after the same interval, and open or finishing sessions defer a
cooperative restart (`/v1/status` `remote_transcriptions`; restart reason
`remote_transcription`).

### Cooperative restart

A build script that kills the process can catch the user mid-sentence: the
dictation is lost, and because the process never reached `applicationWillTerminate`
the output-mute a dictation applies is never undone, leaving the Mac silent. So
nothing outside the app decides when it restarts. `scripts/restart-app.sh` (run
by `make-app.sh`) posts `/v1/restart`; `RestartCoordinator` in the app records the
request and acts on it in the first main-actor turn in which
`AudioArbiter.isDictating` is false — key-down through paste, so a check made
inside the app cannot race a trigger-key press the way an external poll-then-kill
can. When it fires it plays `SoundEffect.restarting` (after the output mute has
been restored, so the cue is audible), then hands off to `Relauncher`. If the
trigger key goes down while the cue is playing, the coordinator steps back to
pending rather than kill that dictation. Speech playback does not defer a
restart: a half-spoken sentence is re-queueable by its caller, and a long
read-aloud should not stall a rebuild. The menu's **Restart Voice Operator** uses
the same path.

The script then waits for the old pid to exit, for a new discovery file with a
different pid, and for `/v1/status` to report the version it just built — the
only proof the new binary is what is running.

SIGTERM is routed through `NSApp.terminate` (`TerminationSignal`), so `kill`
still restores the output mute and removes the discovery file, but it does not
wait for a dictation: it remains the escape hatch for a hung app
(`restart-app.sh --force`).

Every speech response carries a `version` that is monotonic per job and bumped
on **every** observable change, including playback ones. It exists because
`?wait=` alone wakes only at a *terminal* state — deliberately, since the job
lifecycle does not mirror the sentence player — which leaves `queued →
speaking` unobservable without spin-polling. A client that echoes the last
version back as `?since=N` gets the wider contract: return as soon as the job
moves past version `N`, still no later than the terminal state or `wait`
seconds. Passing a cursor is the only way to see playback transitions, and the
cursor is what makes it race-free — a client that missed a change while it was
away finds `version > N` already true and returns immediately, rather than
parking to wait for a change that has already happened. `?wait=` without
`since` is unchanged, so callers that only want "tell me when it is over" are
unaffected.

Speech is FIFO. Input is split using Foundation sentence boundaries. The
`character_offset` in every terminal response is a zero-based, end-exclusive
UTF-16 offset into the original input.

A job can mix voices: `{"parts": [{"text": "Kevin here.", "voice": "am_michael"},
…]}` (a part without `voice` uses `af_heart`). Its text is the parts' texts
joined with a single space, and `character_offset` is an offset into that joined
text, so a client that only reads the offset needs nothing new. Sentences are
split per part, so none spans two voices, and each sentence carries its own
voice to playback and to the lookahead. It is one job rather than one per voice
on purpose: separate jobs leave ~0.5 s of silence at each switch (lookahead
does not cross jobs), a dictation barge-in stops only the current job so the
rest would play after the listener finished talking, and each job would report
its own offset. Interruption, `DELETE`, `?since=` and muting treat it exactly
like a single-voice job. While a job runs it advances a whole
sentence at a time, since that is the granularity at which the queue knows
anything. A job a listener *interrupted* reports where the voice actually
stopped, to the word: the reading overlay's timings (`SpokenNarration`) locate
the word being spoken at the moment of the halt, and its end is added to the
start of the sentence it was in. A word counts as heard once it has started, so
the offset matches what the overlay had lit up. A client that stops a job
after the listener began talking over it can say when that was, `DELETE
…?heard_until=<epoch ms>` (Spaceterm and this app share the Mac's clock): the
position is read as it was then, counting back only time the player was
actually playing, at most ten seconds. Every position allows for the output
latency Core Audio reports, which is what a Bluetooth headset's delay comes
down to, and each halt logs it (`tts halt:`). Without word timings — they
resolve asynchronously, and a sentence can be interrupted before its own
arrive — the offset falls back to the last completed sentence. The current
sentence plus the next two are synthesized/
cached ahead of playback to avoid sentence-boundary gaps. Dictation halts the
current sentence and holds the queue until transcription finishes. Muting
immediately halts/cancels every live or queued job; new queue attempts receive
`503 speech_muted`.

### Dictation and command mode

Fn dictation still transcribes and pastes into the frontmost app. Ctrl+Fn is
command mode: the verbatim transcription goes, as newline-delimited JSON, to the
Unix socket of whichever local client registered for commands (latest
registration wins):

```json
{"type":"voice-command","text":"<transcription>"}
```

**Voice Operator knows no client by name** (2026-10-09). A client registers
itself over the loopback API and the registration is saved in
`subscribers.json` (Application Support), so it outlives restarts of either side;
the client re-registers whenever it starts, which keeps its socket path current:

```
PUT    /v1/subscribers/<name>   {"socket": "/abs/path.sock", "commands": true, "events": ["dictation"]}
DELETE /v1/subscribers/<name>
GET    /v1/subscribers
```

`events: ["dictation"]` adds `{"type":"voice-dictation","active":…,"launch":…,"seq":…}`
as each dictation starts and ends (and `false` at launch). Spaceterm is the one
client today: it registers as `spaceterm` with its `hooks.sock` and owns what a
command means. With nobody registered for commands — or the socket unreachable —
the command transcription is recorded and the unrecognized/error cue plays. Clipboard speech and clipboard summarization remain user-facing tools;
the latter is an independent Haiku clipboard utility, not transcript tracking. It asks Haiku
through `claude-print-daemon` (chriswa-devkit `tools/`, found on the interactive shell's PATH),
which runs the signed-in Claude Code; Voice Operator reads no Claude credentials itself.

**Which mode, and when it is decided.** Capture starts the instant Fn goes down,
so the mode cannot be read off the Control flag at that one moment: a Ctrl+Fn
chord is two presses, and Fn habitually lands tens of milliseconds first, which
made real command dictations paste instead. Instead `DictationModeDecision`
(`Core/DictationMode.swift`) keeps the question open for **200 ms** after
key-down while audio already flows:

| Control lands | Result |
|---|---|
| before Fn (held) | command, decided at key-down — nothing to wait for |
| within 200 ms of Fn | command; the decision closes the moment Control arrives |
| after 200 ms | paste, already latched — Control now belongs to the focused app |
| never | paste, at the 200 ms deadline |

Once resolved the mode is latched for the whole dictation; releasing Control
mid-dictation does not downgrade it, and the second press of a double-tap lock
does not re-open it. Nothing on the capture path (mic, gRPC stream, upload pump)
consults the mode, so the window costs no recording latency. The only consumers
are the start cue, menu-bar tint, end cue, and paste-vs-route, and the earliest of
those — the "safe to talk" chirp — waits for CoreAudio's first buffer, which has
never arrived sooner than ~175 ms after key-down (`chirp` in the dictation trace).
The window is therefore all but free; widening it would start delaying that chirp.
Every dictation's trace records `mode=<paste|command>@<ms>` so a mis-read chord
is diagnosable from one log line.

### English transcription preference (2026-07-27, reversed 2026-08-02)

The current Wispr Flow bundle's `transcribeOpenAIAudio` derives a single
selected language and sends it as the string `language` in `/llm/asr` (for
English, `"en"`). Voice Operator supplies `"en"` for dictation. Its gRPC replica
has an unresolved protobuf `Language` enum and therefore cannot reliably send
that preference.

**Original (2026-07-27):** when a language was requested, `WisprFlowTranscriber`
used the confirmed raw `/llm/asr` path rather than silently language-detecting —
trading server formatting for correct language selection.

**Reversed (2026-08-02):** that gate made the formatted path *unreachable*.
`AudioArbiter` passes `"en"` at every call site, so `!language.isEmpty` was
always true and the Baseten-key branch below it never ran — the app silently
served raw Whisper no matter how it was configured. Voice Operator is
single-user and English-only, so server-side language detection is reliable
here and the formatted result is worth more than the explicit preference. The
gate is gone; `language` now applies to the fallback path only.

Confirm which path a dictation took with `grep "flow:" ~/Library/Logs/VoiceOperator.log`
— `flow: gRPC ok — N chars` is the formatted path.

The historical design notes below describe the retired agent-narration system;
they are retained only as reverse-engineering history and are superseded by this
section.

FEATURE: A native macOS menu-bar app that unifies dictation (replacing Wispr Flow) and
spoken Claude Code updates (replacing `transcript-reader.py`) under one audio coordinator,
so dictation always mutes/halts TTS and no spoken update is ever missed.

CAVEATS:
- STT depends on a valid Wispr Flow account/subscription. We lift the Supabase token Wispr
  already stored; Wispr must stay installed + logged-in at least once to seed the refresh
  token. This is deliberate for now (chosen over reimplementing their login).
- We are consuming Wispr's private, unversioned HTTP/WebSocket endpoints. They can change
  without notice. Everything Wispr-specific is quarantined behind the `Transcriber` protocol
  so a future local/on-device engine (or a vendor swap) is a drop-in replacement.
- Lifting/using a live auth token is inherent to approach "A". The token is read at runtime
  from Wispr's `session.json` and never copied into this repo, logs, or committed files.

---

## Scope (v1)

In:
- **Dictation**: hold-to-talk + double-tap-to-toggle (+ ⌘ mid-hold to promote a hold to
  a transcribe lock), transcription pasted into the focused
  app, with matched start/stop/**pasted** SFX.
- **Claude Code narration**: watch transcripts, summarize each completed turn, speak it in a
  sticky per-session name+voice ("Waldo here. …"), forward speaking events to spaceterm.
- **Audio arbitration**: dictation mutes system output + halts current TTS + defers queued
  TTS until listening ends + a short delay. Interrupted utterances re-cue from the start.
- **TTS audio cache**: every synthesized stream cached ≥1 day, keyed by (text, voice),
  replayed for free.
- **Menu bar UI**: live status (idle / listening / transcribing / pasting / speaking), and a
  quick **Pause** toggle (for meetings).

Out (deferred):
- Historical replay UI. On-device STT/TTS. Reimplementing Wispr login.
  (Command mode — including addressing an agent by call-sign and asking the summarizer about
  its work — has since shipped; see [Voice commands](#voice-commands-command-mode).)
- Formatting note: v1 **does** match Wispr's text formatting via their `/llm` endpoints
  (chosen over shipping raw ASR first).

---

## Reverse-engineering findings (Wispr Flow 2026-07, `com.electron.wispr-flow`)

### Auth — Supabase JWT (approach A: lift the stored token)
- `~/Library/Application Support/Wispr Flow/session.json` holds
  `sb-dodjkfqhwrzqjwkfnthl-auth-token` = `{access_token, refresh_token, expires_at,
  expires_in(=604800, 1wk), token_type, user}`.
- `access_token` is a Supabase HS256 JWT: `iss=https://dodjkfqhwrzqjwkfnthl.supabase.co/auth/v1`,
  `aud=authenticated`. Sent as `Authorization: Bearer <jwt>` to `api.wisprflow.ai`.
- Refresh ourselves (no Wispr app needed at refresh time) via the standard Supabase endpoint:
  `POST https://dodjkfqhwrzqjwkfnthl.supabase.co/auth/v1/token?grant_type=refresh_token`
  with the `apikey` (the Supabase anon key is embedded in the bundle) + `{refresh_token}`.

### STT — HTTP + WebSocket (NOT gRPC)
The `application/grpc+proto` / `loadPackageDefinition` strings in the bundle are grpc-js's
internal channelz/xds plumbing — a red herring. The ASR path is plain HTTP/WebSocket.
- Hosts (bundle constants): `https://api.wisprflow.ai` (primary), `https://api-east.wisprflow.ai`
  (failover), `wss://api.wisprflow.ai/` + `wss://api-east.wisprflow.ai/`, local dev
  `http://127.0.0.1:8000` / `ws://127.0.0.1:8300/`.
- **Streaming (primary)**: WebSocket under `wss://api.wisprflow.ai/…/ws`. Sends opus
  `audio_chunks`; receives `partial_transcript` (and final). Mic audio is Opus-encoded
  (`opusEncoder.worker.js`), ~16 kHz mono (`sample_rate`).
- **Fallback (simplest to replicate first)**: `POST /llm/asr` and `POST /llm/asr_audio_chunks`
  (`transcribeOpenAIAudio` / `transcribeOpenAIAudioChunks`, 20 s timeout) — Whisper-based.
- **Chunking (confirmed from Flow 1.5.1095)**: `/llm/asr` enforces a hard ~20 s server-side
  budget — it answers `408 {"detail":"Request timed out"}` beyond it — so it can only handle a
  short clip per request. Flow never sends long audio in one call: it cuts dictations into
  **28-second chunks** (`basetenChunkSizeSeconds = 28`), transcribes each chunk as it
  accumulates mid-dictation (sequentially, one in flight), and joins per-chunk transcripts
  with a single space (`prevAsrText()`, empty chunks dropped). Cuts are fixed-length — no
  silence detection. Flow also caps a dictation at 20 min (warning at 19).
  **This 28 s chunking applies only to the raw `/llm/asr` HTTP path** — it exists to dodge that
  endpoint's 20 s server budget. The primary gRPC stream has no such limit and is never
  re-cut; see "Streaming dictation" below. `WisprTranscriber.transcribe` still chunks any
  >28 s WAV it is handed, because that is the endpoint with the budget.
- **Silence never drops audio (decoded 2026-07-15).** Flow's send loop pushes *every*
  captured packet through transcription — there is no per-chunk volume/silence gate in the
  send path. Its silence tracking (`silentStreamStreakMs`, `longestSilentStreakMs`,
  `silenceAccruedMs`, `numConsecutiveSilentFrames`) drives only (a) **auto-stop** — a 30 s
  silent streak / 10 min accrued-silence "arm" ends the recording (`RecordingStoppedSilence`,
  `noteAutoStop("silence")`) — and (b) **dead-mic watchdogs** (`firstFrameWatchdog`,
  `silentWatchdog`). Audio quality (`SNR<5dB`, `volume<-70dB`, `alignment<0.15`) is judged
  *after* transcription and only raises a `poorAudioQuality` user notice; it never discards
  text. We mirror this: the upload pump sends every encoded packet, and the single silence
  decision is the whole-clip peak/RMS gate in `endDictation` (i.e. skip only when the entire
  recording was silent). An earlier per-chunk gate that dropped individual 28 s slices judged
  in isolation lost soft words and boundary-split words and was removed.
- **Transcription providers (2026-10-11).** Everything from captured audio to pasted text —
  recognition plus any clean-up pass — is one `TranscriptionProvider`
  (`Transcriber/Transcriber.swift`); the arbiter and the remote (phone) path know nothing
  else. A provider opens a `TranscriptionSession` that takes plain 16 kHz PCM16 while the key
  is held and commits at key-up; it owns its own encoding, credentials, fallback
  (`transcribeAfterLiveFailure`) and health reason. `TranscriptionLeg` is one provider's share
  of one dictation — open-while-the-mic-starts, buffer until open, chained in-order sends,
  open-grace, commit, fallback — shared by `AudioArbiter` and `RemoteTranscriptionManager`.
  The primary is Parakeet until the menu says otherwise, on every Mac — Wispr Flow is only
  ever a deliberate choice, greyed out in the menu without a Wispr sign-in to borrow
  (`WisprToken.hasSession`), and nothing Wispr runs unless it is chosen.
  Providers are a hard-coded list (`TranscriptionProviderID`): **Wispr Flow**
  (`Transcriber/WisprFlow/`, opus-encoded inside `WisprFlowSession`) and **Parakeet**
  (`Transcriber/Parakeet/`, FluidAudio, buffers and transcribes at key-up, never retries and
  never falls back to Wispr). The menu picks the primary and an optional **shadow**: a second
  leg fed the same audio whose result is filed on the history entry (`ShadowTranscript`) for
  comparison. The shadow never pastes, never delays anything, and never touches
  `StreamHealth`, which follows the primary only. Remote dictation uses the primary, without
  a shadow (it has no history entry to file one on).
- **Dictation clean-up (2026-10-20).** "Clean Up Transcripts", a top-level menu checkbox
  (`TranscriptionPreferences.cleanup`) wraps the primary in `CleanedUpProvider`
  (`Cleanup/`), so dictation, history retries and phone dictation all paste cleaned text and
  the arbiter is unchanged. The pass is Fluid-1 Mini (a ~2B Qwen fine-tune for dictation
  clean-up by FluidVoice) on a local llama.cpp server. Its licence is personal and
  non-commercial, so the app never downloads the model: the user does, from the README's
  "Transcript clean-up" section, which the menu links to while the model is missing; without it, enabling fails
  and says so.
  - **Server.** `CleanupServer` downloads a pinned llama.cpp release build into
    `Application Support/VoiceOperator/cleanup` (deleting any other build it left there), checks
    the pinned Q6_K GGUF beside it against its SHA-256, and runs `llama-server` as the launchd agent
    `com.chriswa.voiceoperator.cleanup` on `127.0.0.1:56842` (one slot, 4096 context, all
    layers on the GPU). It exists only while the checkbox is on; off unloads it (freeing
    about 2 GB) and "Delete Clean-Up Model" removes the files. `enable` leaves an agent that
    already runs this build's plist alone, so launch and repeated toggles don't drop the warm
    prompt cache. Its log is `~/Library/Logs/VoiceOperator-cleanup.log` (timings only).
  - **Request** (`DictationCleaner`), shaped like FluidVoice's own, which the model was tuned
    on: `Resources/dictation-cleanup.md` as the system turn, the bare transcript as the user
    turn (no app context), ChatML, greedy decoding, `cache_prompt`, and an output budget of
    `max(256, ⌈1.15 × estimate⌉ + 64)` tokens. One difference: the assistant turn is
    pre-filled with an empty `<think></think>`; without it the model sometimes reasons in the
    open and the reasoning would be pasted. The output has any think block stripped, and a
    spoken question the model *answered* is put back as the question.
  - **Prompt.** `dictation-cleanup.md` is our own, written clean-room from a behavioural spec
    because FluidVoice's prompt is unlicensed; a reviewer compared the two and judged them
    similar quality. On the same inputs it matched the original's outputs and ran faster.
  - **Both texts are kept.** Providers return a `Transcript` (the text to paste, plus `raw`:
    what recognition produced before a clean-up rewrote it), and history files `raw` beside
    the transcript; each Recent Dictations entry can copy either.
  - **Failure** never costs the words: any error (server down, timeout, empty output) pastes
    the raw transcript, marks `cleanup-failed` in the dictation's `trace` line and logs why;
    a status line under the checkbox warns while the server is not answering. Warm, a clean-up adds
    about 0.4–0.6 s after Parakeet's result. Live-test with `--cleanup-test [text]`.
- **Streaming dictation (2026-08-04).** The trigger key going down starts three things at
  once: the microphone, the duplex gRPC stream, and a 100 ms upload pump
  (`AudioArbiter.pumpAudio`) that hands each new slice of captured PCM to the provider's
  session (for Wispr, `WisprFlowSession` opus-encodes it and pushes it up the open stream). Key-up sends the tail with `commit: TRUE` and closes the request stream, so
  the only latency the user sees is the tail plus the server's formatting pass — flat
  regardless of dictation length. This replaced a post-hoc unary call that uploaded nothing
  until the key came up (and dialled a fresh TLS connection per call, and cut anything over
  28 s into sequential round trips), which is why a 25 s dictation used to take ~5 s and a 50 s
  one ~10 s. Timings for every phase land in one `trace …` line per dictation
  (`DictationTrace`); the numbers that matter are `audio` (when the mic actually went live) and
  `result - commit` (everything the user waits for).
- **Trigger-key timing.** Recording begins on key-**down**, never after a hold threshold. The
  hold-vs-tap-vs-double-tap ambiguity is resolved on the *stop* side instead: a release inside
  `lockWindow` (500 ms, Wispr's `DICTATION_DEBOUNCE_DELAY`) keeps recording until the window
  closes, and a second press inside it sets transcribe lock. Audio we turn out not to need is free;
  audio we failed to capture is gone. The old 250 ms `holdThreshold` was the main cause of
  dropped opening words. Consequently the start cue now fires on the first real microphone
  buffer (`AudioRecorder.onFirstAudio`) rather than on key-down — it means "safe to talk", so
  it has to be true — and since the mic therefore hears the cue,
  `AudioRecorder.meteringLeadInSeconds` keeps it out of the silence gate's measurement.
- **Formatting / cleanup**: other `/llm/*` REST endpoints, e.g. `/llm/extract_asr_words`,
  `/llm/flow_state_2025`. Proper-noun/punctuation/formatting live here (client dictionary +
  server LLM). Exact request bodies still to be decoded in the spike.

### Text insertion — Swift helper, clipboard + ⌘V + restore
- A native Swift helper receives a `PasteText` IPC request (~35–41 ms). It:
  1. Registers a **lazy** `NSPasteboard` data provider (renders `public.utf8-plain-text` only
     when the target requests it).
  2. Synthesizes ⌘V.
  3. Schedules **clipboard restoration ~500 ms later**, restoring all saved types (observed 3).
- `AXManualAccessibility` is set on the target app only to *read* context (focused textbox,
  `AXWebArea` URL, Cursor/Electron special-casing). Insertion is clipboard-based because
  `AXValue` setting is unreliable across apps (routine `-25205` failures, e.g. Sublime).
- Post-paste async **insertion verification** reads the textbox back; a trailing-boundary NBSP
  trick is applied by the paste policy.
- Ours offers a second technique, switchable from the menu's **Type Text Instead of Pasting**
  checkbox (`PastePreferences`, default off): `KeystrokeTyper` synthesizes one key event per
  grapheme, off the main thread. It never touches the pasteboard, and a newline
  goes out as ⇧↩ so a chat box or Claude Code does not read it as "send". It exists because some
  apps mishandle a real paste — Claude Code drops the leading part of pasted text — and the
  checkbox is there so a bad result is one click away from the clipboard path.
- Characters go out on an **absolute schedule** (event *i* at `start + i × interval`), so the
  0.5 ms `KeystrokeTyper.interval` is the real rate rather than a floor the cost of posting 600
  events is added to — sleeping *between* events turned a nominal 0.5 ms into a measured 0.78 ms.
  A post that misses its slot forfeits the lost time instead of firing the backlog gapless. Every
  insertion logs `keystroke typer: N event(s) in X ms`, so the constant is checkable against what
  the machine actually did.
- The "inserted" cue plays from the insertion's **completion**, not alongside the call: on the
  keystroke path the transcript is still going out for the better part of a second, and a cue at
  the start would announce text that is not there yet.
- **⌘⌃V re-pastes** the last insertion via the clipboard and **⌘⌃⇧V re-types** it via
  `KeystrokeTyper`, both regardless of the checkbox — so either technique is a chord away without
  touching the menu. The chords fire on key-down, so the re-type first waits (up to 2 s) for the
  user to release the modifiers: our events carry empty flags, but an app that reads the hardware
  modifier state instead would see each character as a ⌘⌃ shortcut. `Chord` matches Shift rather
  than ignoring it, which is what lets ⌘⌃V and ⌘⌃⇧V share a keycode — and stops a stray Shift
  aliasing any other chord onto its handler.

### Mute-during-dictation — CoreAudio device mute, gated on now-playing
- On `RecordingStarted`: `shouldMuteAudio: 1` → Volume Manager checks now-playing; if media is
  playing it saves state and `Set system mute state to true for device <id>` (the default
  output device, `kAudioDevicePropertyMute`). If nothing is playing: `Skipping mute`.
- On stop: restores, tracking `wasPreviouslyMuted` so we never unmute audio the user had muted.
- It is a **system output-device mute**, not a Spotify-specific pause.
- Ours mutes unconditionally (no now-playing gate), but it is switchable: the menu's
  **Mute System Audio While Dictating** checkbox (`AudioPreferences`, default on) sets
  `OutputMuter.isEnabled`. `restore()` stays ungated, so turning it off mid-dictation
  still unmutes an output we had already muted.

### Duck-during-narration — Voice Processing I/O

- While a speech job is active, `NarrationDucker` starts an independent silent
  Voice Processing I/O graph configured for medium other-audio ducking. The
  normal TTS players remain their own output path: Voice I/O startup failure
  therefore cannot make a sentence silent.
- Starting the graph takes about as long as synthesizing the first sentence, and
  it reconfigures the output device. On a USB headset dongle (EPOS BTD 800) that
  is an audible cut-out, which used to land on the first words of speech. On
  outputs that are neither built-in nor Bluetooth, the first audio of a job is
  therefore held (`StreamingSpeechPlayer.hold`, synthesis continuing) until the
  ducker is up (`NarrationDucker.ready`), capped at 3 s. The music still cuts
  out briefly as ducking engages; the speech no longer does. Each narration
  logs `tts: first audio held …`. Holding the microphone
  open does not help these devices: a plain input stream alongside Voice
  Processing I/O distorts all output on the EPOS.
- The graph is released when the queue goes idle, a dictation barges in, or the
  app terminates. If a device cannot initialize it, narration continues without
  ducking and the reason is logged.


### Holding the microphone open (2026-09-05)

Opening or closing an input stream on a Bluetooth headset makes it renegotiate its
codec: the AirPods drop out of their music profile into the voice one and back
again, once at the start of a dictation and once at the end. The user hears a delay
plus an obvious quality shift on whatever is playing, and it happens on every single
dictation.

`AudioRecorder.setAlwaysOn(true)` removes the switch by never closing the stream:
the tap and the engine stay up between dictations, and `capturing` (cleared by
`stop()`, set by `start()`) is what decides whether tap buffers are kept or dropped
on the audio thread. `start()` then does **no graph work at all** — it builds a
converter, flips `capturing`, and returns, so the first buffer arrives ~1 buffer
later instead of after a device wake-up. Costs: the microphone indicator stays lit,
and the headset stays in its voice profile for good.

`installTap` is the sharp edge. It answers a bad argument with an ObjC exception,
which no Swift `do/catch` can contain, so it takes the process down — v0.1.24
aborted a second after AirPods reconnected, in `openMic` off the output-device
listener: the default *output* had switched, so the policy asked for the
microphone, but the *input* device was still moving and the format read from the
node no longer matched the bus. The tap is therefore installed with a **nil**
format (meaning "the bus's own", which cannot disagree with itself), only after a
400 ms settle, only with a validated non-zero bus format, always after a
`removeTap` so a double install is impossible, and with retries while the device
is still arriving.

Two things this has to survive, both handled on `engineQueue`:
- **Device changes.** `AVAudioEngineConfigurationChange` tears the graph down when
  AirPods connect or leave, so the held-open tap is rebuilt against the new hardware
  format (`openMicNow`). If a dictation began while that rebuild was queued, the
  rebuild opens for *it* — its own `start()` saw the mic as open and did nothing.
- **A format that changes under a live recording.** `rebuildConverterIfNeededLocked`
  rebuilds the `AVAudioConverter` when tap buffers stop matching it, so a swapped
  device gives a correct transcript rather than a resampled-at-the-wrong-rate one.

Two menu checkboxes drive it (`AudioPreferences`, both default off):
**Keep Microphone Always On**, and, indented under it, **Only When Using AirPods
(Bluetooth)** — which takes the first one over (greyed via `validateMenuItem`, shown
at whatever the rule currently makes true) and follows the default *output* device's
CoreAudio transport type (`OutputDevice.isWireless`, watched by
`OutputDeviceWatcher`). Transport, not device name: AirPods can be renamed and every
other Bluetooth headset has the identical problem. `AppCoordinator.shouldKeepMicrophoneOpen`
is the single place the two settings are resolved into one answer.

**The rebuild must not answer its own notification.** Bringing the microphone up
on a Bluetooth headset *is itself* an `AVAudioEngineConfigurationChange` — the
device flips profile a beat later — so rebuilding for it reopens the microphone
and changes the configuration again. Unguarded that is a loop with no exit but
the device disappearing, and every turn of it is an audible gap in whatever is
playing; with music fighting for the same headset it ran for 23 s straight
(v0.1.28, 2026-09-06). `configurationChanged` therefore ignores a change landing
within `selfInflictedWindow` (1 s) of its own open, and stands down entirely —
closing the microphone and logging loudly — after more than
`maxRebuildsPerWindow` rebuilds in `rebuildWindow` seconds. `setAlwaysOn` clears
that, so an AirPod going back in the ear re-arms it.

### Trigger key
- Wispr uses Fn (keycode 63) via a "Keyboard Service" push-to-talk (`Ptt action down`).
- **Ours**: default to **Right Shift (keycode 60)** during development via a `CGEventTap` on
  `flagsChanged`, configurable, so Wispr Flow (still on Fn) keeps working in parallel until we
  retire it. Migrate to Fn later. (macOS "double-tap Fn" dictation already disabled by user.)

#### Two invariants the key path must keep (2026-08-12)

Both were violated at once, and on a 2019 Intel MacBook Pro running the then-current macOS the
symptom was: tap Fn twice, nothing happens for a second, then the start and stop
cues fire back to back and no dictation runs.

1. **Nothing slow may run on the trigger key's thread.** `AudioArbiter.beginDictation`
   used to be invoked straight from the event-tap callback *on the main thread*, and
   it called `AVAudioEngine.start()` synchronously. Waking an idle built-in
   microphone takes a median of **721 ms** on that machine (p90 990 ms, max 4.4 s;
   ~80 ms on a recent Mac, which is why it only ever showed up at home). The tap is
   now on a dedicated `HotkeyMonitor` run-loop thread, and the device is spun up on
   `AudioRecorder.engineQueue`; `start()` returns in a millisecond or two and
   reports a failed device asynchronously via `onStartFailed`.

2. **Gesture durations come from the events' own timestamps**, never from the clock
   at the moment they are handled. With key handling stalled behind the device
   wake-up, the key-*up* of a 30 ms tap was processed a second after its key-down,
   `held` computed as ~1 s, and `HotkeyMonitor` concluded "push-to-talk hold →
   stop" instead of "first half of a double-tap". macOS separately disables an
   event tap whose callback is that slow (`hotkey tap re-enabled after timeout` in
   the log), which drops the events either side of the gap. (`CGEvent.timestamp`
   is nanoseconds since boot — do not scale it with `mach_timebase_info`; that
   conversion belongs to mach ticks only, and on a 125/3 timebase it inflated
   every hold by ~42× and broke double-tap lock the same way.)

Note the failure mode: a slow key path does not merely feel laggy, it makes the
gesture recogniser read a *different gesture* than the one performed.

#### Transcribe lock mid-dictation — ⌘ while holding the trigger (2026-08-18)

There are three ways to run a dictation, and the third exists because the choice
between the first two has to be made *before* you know how long you will talk:

1. **Hold** Fn, speak, release — push-to-talk.
2. **Double-tap** Fn, speak, tap Fn — transcribe lock.
3. **Hold** Fn, speak, **tap ⌘ while still holding**, release Fn, keep speaking,
   tap Fn to end — a push-to-talk promoted to transcribe lock without interrupting it.

The third is the same `.locked` gesture state as the second, just reached later, so
nothing downstream of `HotkeyMonitor` knows the difference: one dictation, one
recording, one transcript, with speech either side of the ⌘ tap.

Two constraints keep ⌘ from locking a dictation by accident (`trackCommandLock`):

- **Only while the trigger key is physically held** (`.holding`). Notably *not*
  during `.awaitingLock`, where Fn has already been released — a ⌘-shortcut the
  user meant for their own app would otherwise leave the microphone open with
  nothing to close it.
- **On the press edge**, so ⌘ already held when Fn went down is somebody else's
  modifier and is ignored.

Unlike the Shift gesture below this fires on key-*down* rather than waiting for a
clean tap: nothing else reads ⌘ while the trigger is held, so there is no ambiguity
to resolve, and locking immediately means Fn can be released the moment the user
thinks of it.

#### Stop tail — 500 ms more after Fn ends a dictation (2026-10-20)

When Fn itself ends a dictation (releasing a push-to-talk hold, or the press that
ends a transcribe lock), recording continues for `stopTail` (500 ms) before
`onStop` fires, because users tend to end a fraction early and clip their last
word. The gesture sits in `.stopping` meanwhile and ignores Fn. Stops that are not
the user's key — the `lockWindow` timer after a lone quick tap, tap-disable
recovery, phone or API dictation — stop immediately. The key-up cue and the
`trace` latency both start at the real stop, after the tail.

#### Transcript style — left Shift while recording (2026-08-14)

Wispr returns a finished *sentence*: first word capitalised, terminal full stop.
That is wrong when the transcript is being injected into the middle of a line
already written, and hand-editing after every such paste is what this removes.

Tapping **left Shift while a dictation is recording** cycles that dictation's
`TranscriptStyle` through four states — `normal → lowercase first → lowercase +
trim → trim → normal` — each tap flipping one of two flags:

- **lowercase first** — case-fold the first word and prefix a space. Skipped when
  the leading run of letters is an acronym (`API`) or the pronoun `I` (`I`, `I'll`);
  a lone `A` *is* folded, because mid-sentence it is the article.
- **trim end punctuation** — drop one trailing `. , ; : ! ?` and guarantee exactly
  one trailing space.

Both flags add whitespace deliberately: they mean "this goes mid-line", and a
doubled space is harmless where this text is headed while a missing one welds two
words together. The transform is pure (`TranscriptStyle.apply`), applied to the
returned transcript before it is recorded *and* pasted, and skipped entirely for
command-mode dictations, which are spoken to the router rather than written down.

Three things the mechanism has to get right:

1. **The state is ephemeral and per-dictation.** It lives on the `LiveDictation`
   and is latched at key-up alongside the mode, for the same reason: the transcript
   lands long after this dictation stopped being the current one.
2. **Shift is not cycled on key-down.** During a transcribe-locked dictation the
   user is free to type, and Shift is the most-pressed modifier there is — every
   shift-selection and every capital letter would silently reshape the transcript.
   A press only *arms* the gesture; any other key, click, or modifier change while
   Shift is held disarms it; the cycle happens on release.
3. **Left Shift is identified by its device-dependent bit** (`0x2`,
   `NX_DEVICELSHIFTKEYMASK`), not the generic `maskShift` — which cannot tell the
   two Shift keys apart, so releasing the left one while the right is held would
   read as a second press.

The state shows as amber `a` / `x` badges on the menu-bar icon, drawn *after* the
status tint fill (a `sourceAtop` fill would otherwise repaint them red) and only
while capturing — the same instants the icon is red, which is exactly when the key
does anything. `--icon-preview` renders all four states, magnified, over light and
dark menu-bar backgrounds.

There is no audible cue, and cannot usefully be one: `OutputMuter` hardware-mutes
the default output device for the whole recording, so a cue at press time would be
silent on any device that has a mute control.

The residual cost of a cold device — roughly a second before the "safe to talk"
chirp, and the words spoken into it — is deliberately not fixed by keeping the
engine warm: that would hold the input device open and light the macOS
microphone-in-use indicator permanently. The `audio=` mark in each dictation's
`trace` line is the measurement of that deaf time.

---

## Architecture — Swift menu-bar app (`LSUIElement`, no dock/window)

```
Core/
  AudioArbiter        the brain: mute + halt + TTS queue + coordination invariant
  NameVoiceRegistry   gender-aligned name allowlist; sticky (claudeSessionId, spaceTermId)->(name,voice); idle TTL
  AudioCache          TTS PCM cached by (text, voiceId) hash, >=1 day, free replay
Transcriber/  (protocol Transcriber)   WisprTranscriber today (WS + /llm HTTP); LocalWhisper later
Speaker/      (protocol SpeechSynthesizer)  KokoroSynthesizer (local kokoro-82m HTTP, streaming)
Inserter/                              Swift paste helper (lazy clipboard + Cmd-V + restore + AX ctx)
ClaudeWatcher/                         ports transcript-reader.py: tail, Haiku-summarize, spaceterm sock
Hotkey/                                CGEventTap on Fn; hold / double-tap / Cmd-mid-hold to lock
MenuBarUI/                             status states + Pause toggle
```

**Build identity.** Every bundle build — local or release — allocates its own version
(`allocate_version`, `scripts/lib.sh`): `MAJOR.MINOR` is the release line from the committed
`Info.plist`, `PATCH` is a monotonic counter in the untracked `.build-number`. The number is
stamped into the *bundle's* `Info.plist` with the source commit, logged at launch, and shown
in the menu above **Restart Voice Operator** (`BuildInfo`). That last part is the point: a
running instance keeps executing the binary that was deleted out from under it, so the only
proof a restart picked up the last build is the version changing. Two builds of identical
source therefore still differ. `scripts/bump-version.sh` allocates a release's version into
the committed plist, whose patch component doubles as the counter's floor — so a fresh clone
resumes above the last release instead of re-issuing published numbers.

**`AudioArbiter` invariant** (the reason this app exists): dictation-start → halt current TTS
(re-cue from start) + mute output + block queue; dictation-end (+delay) → unmute + drain queue.
This fixes "a TTS update arrives while I'm dictating and I miss it."

**Provider boundaries** so the STT and TTS backends are swappable: `Transcriber`
(audio→text), `SpeechSynthesizer` (text→audio), each behind a protocol with the vendor
client fully contained.

### TTS — Kokoro (local `kokoro-82m` HTTP server)

The app synthesizes speech through a local Kokoro server (`KokoroSynthesizer`), replacing
the earlier Cartesia integration (removed 2026-07-09 when the Cartesia quota ran out; recover
it from git history if ever needed). It's a plain, self-documented HTTP service — no API key,
no reverse-engineering. The server itself lives in this repo under `kokoro/` (merged from the
old `tts` repo with its history, 2026-10-07; see `kokoro/CLAUDE.md`).

**Service (2026-10-07; local only since 2026-10-13).** Speech always goes to the local
Kokoro at `KokoroSynthesizer.baseURL` (`127.0.0.1:56841`). The custom-server option
(`TTSProvider.custom`, `config.json` `tts.url`/`tts.headers`, `$VOICEOP_KOKORO_URL`) was
removed with incognito mode so that what is spoken cannot leave the Mac; recover it from
git history if a remote server is ever needed again. The local server is installed and run by `KokoroService`: the
server files ship in `Contents/Resources/kokoro`, Install builds a venv on a private
uv-managed Python 3.13 in Application Support (using the Mac's `uv`, or a pinned, checksummed
download) and bootstraps one launchd agent (`com.chriswa.voiceoperator.kokoro`, `KeepAlive`,
no scheduled restart). It runs unprompted: installed at launch when missing (unless the user
uninstalled it), updated when the app ships a different server, with a setup window showing
progress. The app is self-contained — no other checkout is involved. Anything that stops the server
waits until nothing is dictated or spoken. `/health` reports the server's physical footprint
(`memory_mb`), shown under the submenu's status line — the guard against the MPS leak the old
02:00 restart existed for.

- `POST {base}/synthesize`, `Content-Type: application/json`,
  body `{ "text": <string ≤5000>, "voice": <voice id>, "speed": <0.5–2.0, default 1.2> }`.
  Base URL is always `http://127.0.0.1:56841`.
- Response is one streaming `audio/wav` body: a **44-byte PCM WAV header** (with placeholder
  `0xffffffff` RIFF/data sizes, since length isn't known up front) followed by raw
  **s16le PCM, mono, 24000 Hz**, flushed as generated so playback starts on the first chunk.
  `KokoroSynthesizer` strips the header and converts s16le→`pcm_f32le` to feed the existing
  f32le streaming pipeline; the cache rebuilds a canonical, real-size WAV.
- `GET {base}/voices` lists the voices. We use the 27 English ones (American `af_`/`am_`,
  British `bf_`/`bm_`); `NameVoiceTable` maps the full 81-name Cartesia-era roster onto them
  (~3 gender-matched call-signs per voice) so the name pool stays deep, while
  `NameVoiceRegistry` hands each concurrent session a distinct voice until all 27 are in use.
- `POST {base}/timestamps` (same body as `/synthesize`) returns word-level timings as JSON
  `{ words: [{ word, start, end }], duration, ... }`, times in seconds from the first audible
  sample. Kokoro's duration predictor assigns frames to every phoneme before the vocoder runs,
  so these are the model's own alignment, not a forced-alignment pass. A **separate** call from
  the audio stream on purpose: `/synthesize`'s body must stay byte-exact PCM, and a word's end
  time isn't known until its chunk is generated (can't front-load without killing TTFA). Timings
  are deterministic for a given (text, voice, speed), so the two responses stay in lock-step.
  `KokoroSynthesizer.wordTimings` fetches them; `TTSEngine` memoizes per clip.

### Word-highlight overlay

While TTS plays, a full-width black bar aligned to the bottom of the screen shows the sentence being spoken
(`Overlay/WordOverlayController` + `WordOverlayView`, driven from `AudioArbiter`). The whole sentence
renders as one line — the current word bright, the surrounding context words dim — and the line runs
off both screen edges (no wrapping). It is aligned Spritz/RSVP-style: the current word's **Optimal
Recognition Point** (`ORP.pivotIndex`) is pinned to a fixed horizontal focal point (marked by a dim
vertical guide), so the reader's eye stays parked on one spot as the line shifts word to word. The line
shows the sentence **as written**: `buildContext` aligns the timing tokens back onto the original text
with a greedy forward substring scan (`alignedContext`), keeping punctuation and spacing. Kokoro's
tokens are faithful substrings (numbers, contractions, hyphenates, abbreviations, even curly
apostrophes all matched in testing), so this holds in practice; if a token can't be located (some
normalisation), it falls back to joining tokens with spaces and logs it. Cross-sentence context isn't
stitched — each sentence renders on its own.

To get finer per-piece timing and cleaner speech, `TTSPreprocess.prepare` rewrites the text sent to the
TTS server (both `/synthesize` and `/timestamps`, so audio and timing match) and returns a character map
(`origPositions`) from the spoken text back to the original: a `/` between alphanumerics is spoken as
"slash" (`src/main` → "src slash main"), a `.` inside a path token (one containing `/`) as "dot"
(`app.swift` → "app dot swift"), a `-`/`_` between alphanumerics becomes a space (`state-of-the-art` →
per-word timing, separators dim), and `*` is dropped so markdown emphasis isn't read as "asterisk". The
overlay aligns the timing tokens against the *spoken* text and maps each match back through the character
map, so it displays the ORIGINAL text and a `/` or `.` spoken as a word still highlights the literal
character. Without this a whole path or hyphenated compound is one multi-second token that highlights as a
single block, and stray markdown is read aloud.
A dim (30% white) vertical guide inside the band marks the fixation point, at the pivot letter's
**x-height centre** — the
word is positioned so its lowercase-body midline lands at the centre of the bottom band, which is where the eye
fixates in reading (not the em-box centre, which sits high on ascender space). The overlay window is
full-screen and transparent, painting only the guides, the band and the word; glyphs carry no stroke
(a stroke leaves join artifacts in the letters' bowls).
The bar samples the player's source-audio position at 60 Hz against the fetched timings.
Each sentence's timings are offset by its actual PCM start in the job timeline. Speed changes,
network gaps and cross-sentence rewind therefore move the reader with the audio; there is no
wall-clock sentence anchor. Placement: bottom, lower middle, middle, upper middle, top (under the menu bar) or hidden
(the two in-betweens sit halfway between their neighbours),
cycled by ⌘⌃/ or chosen in the menu's **Word Overlay** submenu (`OverlayPreferences.placement`, default bottom;
an old `wordOverlayEnabled = false` reads as hidden).

### Live TTS playback controls

- **⌘⌃,** / **⌘⌃.** slow down / speed up playback by **0.2×**, clamped to **0.5×–5.0×**.
  The multiplier is relative to the existing Kokoro rendition (synthesized with its unchanged
  1.2 generation speed). `PlaybackPreferences` saves `vo.playbackRate` in the app's UserDefaults
  preferences file, surviving new jobs, cancellation and restart. Missing/invalid settings
  default to 1.0×; out-of-range values are clamped.
- **⌘⌃←** rewinds **3 source-audio seconds**, crossing any number of preceding sentences
  within the same job and clamping only at the job's beginning.
- **⌘⌃→** skips ahead **3 source-audio seconds** within the active job. A target beyond
  received audio carries forward through subsequent packets/sentences, skipping them until
  the target is reached (or the job ends). Skipped PCM remains available for rewind.
- The finished job stays rewindable for **two seconds**. Rewind revives its local audio and
  visual reader, keeps its rate, and opens another two-second window when replay finishes.
  Its HTTP result stays completed. A new job replaces the retained session immediately;
  dictation, mute or stopping playback discards it. Replayed speech counts as speaking for
  ducking, `/v1/status` and cooperative restart.

`TTSEngine` feeds both cached WAVs and fresh PCM into one job-scoped `StreamingSpeechPlayer`
(`AVAudioPlayerNode → AVAudioUnitTimePitch → mixer`). Received buffers are retained until the
grace expires or the job is replaced/cancelled (float32 mono uses about 5.8 MB per minute of
source audio). Rewind reschedules these buffers without restarting synthesis or fetching
audio again. A generation token ignores completion callbacks from pre-seek schedules.
`PlaybackTimeline` maps node sample positions into source audio, excluding underrun gaps;
the overlay keeps each original sentence's text/timings so it can follow backwards as well
as forwards. The stall watchdog watches progress, not total playing time, so slow playback
and repeated rewinds cannot trigger a false timeout.

The reader draws tiny solid black directional triangles centered vertically and horizontally
within its top white border. Each 0.2× difference from 1.0× adds a triangle (partial clamp steps round
up); slower points left, faster points right, and 1.0× draws nothing. This refreshes immediately
on adjustment and stays visible through sentence gaps. Menu equivalents show the controls
and current speed. The event tap consumes reader chords
only while their actions are available, leaving them to the frontmost app at idle. The menu
handles its own equivalents while tracking, and Secure Keyboard Entry has the same limitations
as the existing global shortcuts. `PlaybackTimelineTests` silently exercise the real audio
graph in offline rendering mode, including live rate changes and cross-sentence seeks.

---

## Hands-free (2026-10-24)

Hands-free — always listening for a client's trigger word, dictating until the
speaker is finished, a conversation window after — lives here. It moved from
Spaceterm, which is now one client of it (`docs/hands-free-plan.md` has the
migration and its decisions). Nothing listens until a client connects and asks,
and nothing outlives the connection that asked.

**Code.** `HandsFree/`: `HandsFreeService` (the socket, clients, sessions,
sources), `HandsFreeEngine` (one source's state machine, ported from Spaceterm's
`src/mobile/hands-free.ts`), `Listener` (speech gate, wake listener, utterance
endpointer — `wake-listener.ts`), `Phrases` (trigger words, filler, shutdown
phrases), `SileroVAD` and `SmartTurn` (the same ONNX models Spaceterm ran,
on ONNX Runtime), `HandsFreeRecord` (the decision record). Live-test it with
`--hands-free-test [text]`, which streams `say`-made speech as a phone would.

**Sources.** The Mac's microphone — a second reader on `AudioRecorder`'s tap
(`setListener`), which holds the microphone open while set and never touches a
Fn recording beside it — is one source shared by every client that started a
session there. A client's stream (a phone, through the iOS SDK) is a source of
its own. One session per client: starting one ends its other.

**When it does not listen.** On the Mac: during a Fn dictation; while Voice
Operator speaks on the built-in speakers (and `playbackTailMs` after), because
the microphone would hear it; while a client says it is `playing`. On a
stream: while the device plays without `echoCancelled`, which the SDK reports
only when the sound goes into an ear (AirPods, any headset). On the phone's
own speaker its echo cancellation let the start of Control's replies through
as the user cutting in (October 25), so there, as on the Mac's speakers,
hands-free does not listen while the phone plays, and cutting in by voice
needs a headset. Voice cut-in on the
Mac therefore needs a headset, as it did in Spaceterm.

**Incognito** ends every session and refuses new ones: what hands-free hears
goes to a client.

**Debugging it.** `hands-free/decisions.jsonl` in Application Support has a
line per decision, with the clip it was made on in `clips/`: `check` (what
Apple's model heard), `turn` (Smart Turn), `dictation`, `levels` (the room,
every 30 s), `silent-input` (digital silence: a closed lid, a muted input),
`interrupt` (what cut the client's voice off, and `intoReplyMs` — how far into
the reply), and `echo` per reply the client played through echo cancellation
(how much still sounded like speech, `firstSpeechMs`, peak level, ducks,
cut-ins), and `pause` per pause in a dictation: Smart Turn's answer,
turn-1-mini's at the pause, its peak through it (and when), and when it first
reached its threshold (`miniCrossedMs`, when it would have ended the turn), how
long the silence lasted, and whether they carried on (`resumed`) or it ended
the dictation; `started` and `ended` per dictation, with when its speech
started and ended (wall time, the quiet that ended it not counted) and, on
`started`, the gap since the last one's speech ended and what ended that one —
a short gap after a `finished` is Smart Turn ending a turn too early — the data for setting both models' thresholds on this user's
speech; and `mini-ending` for each time turn-1-mini crossed its threshold in a
silence, then `ended` the dictation half a second later or was `cancelled` by
speech in that half second (when, and Smart Turn's answer beside it).
turn-1-mini (p99lab, Apache-2.0, "turn-1-mini by p99lab",
huggingface.co/p99lab/turn-1-mini) decides when a dictation ends: `TurnOneMini`,
a streaming model fed the whole dictation in 160 ms steps. Smart Turn runs
beside it for comparison only; the silence timeout is the fallback. Echo leaking through always starts at about the same `intoReplyMs`;
a person interrupting does not.

### Protocol (version 1)

Newline-delimited JSON over the Unix socket named in `speech-service.json` as
`hands_free_socket` (`~/Library/Application Support/VoiceOperator/hands-free.sock`).
Unknown fields are ignored.

**Control connection** — one per client, held for as long as it wants
hands-free:

| Client sends | Meaning |
| --- | --- |
| `{"type":"hello","protocol":1,"client":"spaceterm","trigger":"control"}` | Register. `welcome` or `refused` (`protocol`, `invalid_client`, `invalid_trigger`, `client_taken`, `trigger_taken`) and the connection is closed. Registration lasts as long as the connection. |
| `{"type":"start","source":"mac"}` | Hands-free on, on the Mac's microphone. Answered with `session`. |
| `{"type":"stop"}` | Off, wherever it is on. |
| `{"type":"playing","on":bool}` | The client is playing sound of its own on the Mac (a cue): not listened through, plus a tail. |

**Stream connection** — a device's audio, for a client already registered:

| Client sends | Meaning |
| --- | --- |
| `{"type":"hello","protocol":1,"client":"spaceterm","role":"stream","device":"iPhone"}` | `welcome`, or `refused` `no_client`. |
| `{"type":"start","sampleRate":16000,"codec":"pcm16"}` | Hands-free on, on this stream: `session {source:"stream", session:<id>}`. |
| `{"type":"resume","session":<id>}` | After a dropout, within 10 s: `resumed {session, at}` — send audio from sample `at` (16 kHz). Otherwise `session-ended {why:"lost"}`. |
| `{"type":"audio","at":<n>,"data":<base64 s16le mono>}` | `at` is the 16 kHz sample position of the chunk's first sample (at the stream's own rate it is converted). Overlap with what was received is dropped; a hole resets listening. Acked about once a second: `ack {at}` — the SDK may forget audio before it. |
| `{"type":"playing","on":bool,"speech":bool,"echoCancelled":bool}` | The device is playing; `speech`: the client's voice, which hands-free turns down for the user and can cut off; `echoCancelled`: the microphone does not hear it. |
| `{"type":"stop"}` | Off. |

Audio a resumed stream replays from more than 2 s ago resets listening unless a
dictation was under way: it is history, not the user talking now.

**Voice Operator sends**, on the connection that started the session:

| Message | Meaning |
| --- | --- |
| `session {source, session?}` / `session-ended {why}` | On / off: `off`, `shutdown` (said by voice), `replaced`, `lost`, `restarting` (Voice Operator is quitting — a client may keep hands-free on and start it again when it is back), `incognito`, `unsupported_audio`. |
| `state {phase, conversation, closesAt, checking, pending}` | `phase`: `off`, `listening`, `hearing` (the user is being dictated — hold your own voice), `sending`. `closesAt` (wall ms) when the window closes if nobody speaks; null while held open. `pending`: speech that needs the trigger word is undecided — play a "deciding" beep while true. Sent on change. |
| `gauge {quietSince, patienceMs, turn, threshold, sampling, mini, miniPeak, miniThreshold}` | While dictating: the quiet since `quietSince` (wall ms; null while they talk) ends it at `patienceMs`; `turn` is Smart Turn's one answer about this pause (asked once, 0.5 s in) against its `threshold` — shown and recorded, deciding nothing since October 25; `sampling` while it is being asked. `mini` is turn-1-mini's latest answer and `miniPeak` its highest since the pause began (null while they talk), against `miniThreshold` (0.5 on trial; the model card's points are 0.06–0.17): it ends the dictation, 0.5 s after it first reaches the threshold in a silence unless speech comes back first. Data points, sent on change — animate between them. |
| `cue {name, haptic?}` | `ready`, `dictationStart` (tap), `dictationEnd` (double), `notWakeWord` (three in a row at most, and none after "stop listening", until the trigger word opens the window again), `conversationClosed` (triple; the window ran out, or "stop listening" — whose `transcript` is empty), `shutdown`, `error`. The client decides how each sounds or feels. |
| `duck {on}` | Turn the client's voice down (someone is talking over it) or back up. |
| `cut-in {msAgo, at}` | The user cut the client's voice off: they began `msAgo` ms ago (`at`, wall ms), which is as far as they heard it. |
| `transcript {text, trigger, interrupted, reason, shutdown}` | The dictation, trigger word included — strip it yourself. Empty when nothing was caught; `interrupted`: it cut the client's voice off (with empty text: say you had not finished, and carry on). `shutdown`: "let me turn this off" or "<trigger>, shutdown" — hands-free turns itself off: `session-ended {why:"shutdown"}` follows. |
| `ack {at}`, `resumed {session, at}` | Stream bookkeeping, above. |

## Speech on a device (2026-10-25)

Speech a client wants heard on a device that plays it itself — a phone, through
the iOS SDK's `VoiceOperatorSpeech` (or anything speaking the same protocol) —
is a Voice Operator job like any other: `POST /v1/speech` with `client` and
`device`, then `GET`/`DELETE /v1/speech/{id}` exactly as for speech played
here, `character_offset` and `heard_until` included. `DeviceSpeech` keeps the
job: it splits it as the Mac's speech is split (`SpeechJobManager.segments`),
makes each sentence in turn (`RemoteSynthesis`: `TTSPreprocess`, Kokoro with
word timings, `SpeechLoudness`), sends it to the device, and counts what was
heard from the device's reports of each sentence starting and finishing — word
by word, from the timings, for a sentence cut part way (also for a `heard_until`
before now). It moved here from Spaceterm's `RemoteSpeech`, so any client gets it.

Which device speech goes to is the client's call: Spaceterm sends Control's
replies to the phone holding Control while it is connected. A device's jobs are
made one after another, in the order asked for; they do not queue behind the
Mac's speech, a dictation here does not stop them, and the menu's mute does not
silence them (the client has its own). Job ids start `ds_`. A job in progress
holds off a restart, as speech here does (`speaking` in `/v1/status`).

**Protocol.** A **speaker** connection on the client socket (the one in
`hands_free_socket`, newline-delimited JSON, as hands-free's), one per device.
No trigger word or control connection is needed.

| Device sends | Meaning |
| --- | --- |
| `{"type":"hello","protocol":1,"client":"spaceterm","role":"speaker","device":"<id>"}` | `welcome`, or `refused` (`protocol`, `invalid_client`, `invalid_device`). A second hello as the same client and device replaces the first: it is sent `replaced`, and what it was playing ends where it got to. |
| `{"type":"progress","id","index","event"}` | `started` (its first sample is audible), `finished` (its last), or `failed` (it cannot be played: the job ends `synthesis_failed`). Timed on arrival, on the Mac's clock. |

| Voice Operator sends | Meaning |
| --- | --- |
| `sentence {id, index, count, sampleRate, pcm, sentAt, synthMs}` | One sentence to play after whatever is queued: base64 s16le mono at `sampleRate`. `sentAt` (wall ms) and `synthMs` are for the device's record. |
| `ended {id, state, characterOffset}` | The job is over; stop anything left of it unless `state` is `completed`. |
| `replaced` | Another connection is this device now. |

A speaker connection that closes ends its jobs where they got to
(`cancelled_by_client`); there is no resume — the next job goes to whichever
connection is the device's then.

## Incognito mode (2026-10-13)

A menu checkbox (`Incognito`, persisted in `UserDefaults` as `vo.incognito`, so a restart
cannot drop it) under which nothing the user says or hears leaves the Mac or is written to
disk. The menu-bar icon's base symbol becomes `sunglasses.fill`; every tint, ring and badge
draws over it unchanged, and the discard trash can still wins. `/v1/status` reports
`"incognito"`.

**Where it is enforced.** Not at one switch near the UI: every network client and every
content-bearing writer calls `Incognito.check`/`refusal` itself, at the lowest level it owns,
so a new caller cannot get round it by forgetting. Higher-level checks exist only for a clean
error. `IncognitoTests` asks each gate directly.

| Refused | Gate |
|---|---|
| Wispr Flow (gRPC stream, `/llm/asr`, token refresh, dictionary sync) | `FlowChannel.sharedChannel`, `WisprTranscriber`, `WisprToken.refresh`, `WisprDictionary.fetchEntries`; `WisprFlowProvider` fails first so the error names Wispr. As primary that is a loud `StreamHealth` ("Dictation is off … choose Parakeet"); a Wispr shadow is skipped (a shadow's only product is a history entry). Turning incognito on also closes the keepalive'd channel. |
| Clipboard summaries (Claude via `claude-print-daemon`) | `ClaudeSummarizer.askHaiku`, before the prompt file is written |
| Dictation history and clips | `AudioArbiter.record`/`persist`, `HistoryStore.save`. Nothing is filed, not even in memory, and re-paste forgets the last transcript. The recorder no longer writes a temp WAV at all (in either mode): the clip stays in memory and is only written when history keeps it. |
| TTS audio cache | `AudioCache.store`. `TTSEngine` keeps lookahead clips in memory instead, each dropped once played and all of them (and the word timings) on `stop()` |
| Words in the log | `Log.clip` logs only the length |
| HTTP cache (`~/Library/Caches/com.chriswa.voiceoperator`) | Not incognito-specific: Kokoro requests use an ephemeral `URLSession` and `URLCache.shared` has no disk capacity, in every mode. `URLSession.shared` had been caching TTS request text, `/timestamps` words and the audio itself — the first incognito test found a sentence there. |
| Spaceterm and other clients: `/v1/transcriptions`, `/v1/synthesize`, speech on a device, `/v1/wake-word`, subscriber sockets (commands and dictation events) | `RemoteTranscriptionManager`, `WakeWordCheck.check`, the `/v1/synthesize` handler, `DeviceSpeech` (refuses the job, and each sentence as it is about to be sent), `SubscriberSocket`; HTTP refusals are 403 `{"error":"incognito"}`. Spaceterm is local, so this is policy rather than necessity: it has its own switch, `Incognito.blocksSpaceterm`. |

Still allowed: Parakeet (on device; FluidAudio only touches the network to download model
weights), the local Kokoro, dictation clean-up (loopback llama.cpp; its `URLSession` is
ephemeral and its log carries no text), `/v1/speech` (text coming *in* to be spoken here), and reading
the existing caches. The clipboard paste marks its item `org.nspasteboard.TransientType` and
`ConcealedType` (in both modes) so clipboard managers skip it; Universal Clipboard is not
known to honour those, so Handoff should be off in System Settings for incognito to hold.

## Voice commands (command mode)

Superseded (2026-10-09). The name-first grammar, call-signs, `repeat`/`focus`/`skip`
and Haiku "asides" left with transcript tracking; Voice Operator no longer interprets
commands at all. Ctrl+Fn hands the verbatim transcription to the registered command
client; see **Dictation and command mode** above.

---

## Phased plan

- **Phase 0 — STT spike (Node/TS, static-decode only).** Prove `mic → opus → transcript →
  /llm format → formatted text` standalone, reading the token from `session.json` at runtime.
  Milestone A (easy): record a short WAV → opus → `POST /llm/asr` → raw transcript.
  Milestone B: `wss://…/ws` streaming with partial transcripts.
  Milestone C: decode + call the `/llm` formatting endpoint; confirm output matches Wispr.
  Also verify Supabase refresh works headless. Node chosen to mirror Wispr's own JS client
  (grpc-js is irrelevant; `ws` + `fetch` + an opus encoder suffice).
- **Phase 1 — Swift app skeleton.** Menu bar, Hotkey (Right Shift), CoreAudio mute, SFX,
  Inserter (paste helper), wired to a stub Transcriber. End-to-end dictation → paste.
- **Phase 2 — Port the proven STT** into `WisprTranscriber` (Swift), behind the protocol.
- **Phase 3 — Speaker + ClaudeWatcher + AudioArbiter.** Streaming TTS with cache, transcript
  watching/summarization, name/voice registry, spaceterm forwarding, full arbitration.
- **Phase 4 — Retire** Wispr Flow (move trigger to Fn) and `transcript-reader.py`.

## Spike results (Phase 0)

**Milestone A — PROVEN (2026-07-02).** One real call validated the whole approach-A keystone:
- Token: read `session.json` → 1309-char JWT; usable directly, no Wispr app interaction.
- Auth header is the **raw** access token (`Authorization: <jwt>`, NOT `Bearer <jwt>`).
- `POST https://api.wisprflow.ai/llm/asr`, `Content-Type: application/json`,
  body `{ audio: base64(16 kHz mono s16le WAV), language: "en", prompt: "" }`.
- Response `HTTP 200` → `{ "content": "<transcript>", "detected_language": "en" }`.
  Output is already punctuated/capitalized (Whisper). Code: `spike/asr_spike.py`.
- Supabase anon key (public, role=anon) extracted for headless refresh: in `spike/wispr_token.py`.

**Endpoint etiquette:** the spike issues exactly one request per run (no polling/retries).

## Build status (as of this checkpoint)

- **Phase 0 (STT spike):** ✅ done + ported to Swift (`WisprTranscriber`, validated).
- **Phase 1 (Swift app skeleton):** ✅ builds clean, dictation pipeline wired end to end:
  `HotkeyMonitor` (Right Shift) → `OutputMuter` (CoreAudio mute) → `AudioRecorder`
  (AVAudioEngine→WAV) → `WisprTranscriber` (`/llm/asr`) → `TextInserter` (clipboard+⌘V+restore),
  with `SoundEffect` cues and the `MenuBarController` bullhorn (red=recording, green=playing).
  `AudioArbiter` coordinates. App bundle via `scripts/make-app.sh`.
- **Name/voice registry:** ✅ `NameVoiceTable` (81 gender-aligned call-signs mapped onto the
  27 English Kokoro voices, ~3 names/voice; call-sign gender matches the voice's reported
  gender) + `NameVoiceRegistry` (sticky, no active name reuse, prefers a distinct voice per
  concurrent session until the 27-voice pool is exhausted, idle TTL) with passing unit tests.
- **Phase 3 (TTS half):** ✅ built + validated. `KokoroSynthesizer` (local `/synthesize`, streaming),
  `AudioCache` (≥1-day WAV cache, free replay), `SpeechPlayer` (haltable/awaitable),
  `TTSEngine`, and the `AudioArbiter` TTS queue with **barge-in re-cue** (dictation halts +
  re-queues the interrupted utterance from the start). `ClaudeWatcher` = `TranscriptParser`
  (unit-tested) + `ClaudeSummarizer` (Keychain OAuth → Haiku) + `TranscriptWatcher` (tail,
  mute headless/bg — orphaned Bash tasks whose completion notification the harness never
  persisted are resolved by probing whether anything still holds the task's `.output` file
  open — sticky name/voice, idle TTL) + `SpacetermSocket` (tts-speaking events, and
  a `session-names` event: the full Claude-session→call-sign map, broadcast whole on
  every registry change and once on startup).
  All three external integrations validated with one live call each:
  `--asr-test`, `--tts-test`, `--summarize-test`.
- **Phase 4 (retire Wispr + transcript-reader.py, move to Fn):** ⏳ pending live use.
- **Blocked on user:** macOS Accessibility + Microphone grants to verify the full live loop
  (dictation paste + Claude narration) in the real app bundle.

## Open items (remaining spike milestones)
- **Milestone B** — `wss://api.wisprflow.ai/…/ws` streaming: exact path + handshake (auth via
  header vs query param) + per-message JSON schema (opus `audio_chunks` up, `partial_transcript`
  down). Lower priority now that HTTP `/llm/asr` is proven sufficient for v1.
- **Dictionary prompt-biasing — REVERTED (2026-07-08).** The 2026-07-07 change that passed the
  dictionary as the `/llm/asr` `prompt` degraded transcription: Whisper's `prompt` is
  autoregressive *previous-transcript* context, not a spelling dictionary, so it regurgitated the
  word list on quiet chunks, injected unspoken words, and over-corrected. Reverted to an empty
  prompt (`WisprTranscriber`). `WisprDictionary` is kept as infrastructure for the flow-request
  `dictionary_context` path below (the correct biasing channel). **Read the app, don't probe the
  live API** (see `CLAUDE.md`).

- **Milestone C — SHIPPED: formatted gRPC dictation (Wispr parity) (2026-07-08; client
  on grpc-swift 1.x as of 2026-08-02 for the latest macOS release / universal).**
  Full ground-truth decode from the Wispr Flow app bundle (`serializeFlowRequest` + the
  `flow_api.v1` protobuf), captured in `spike/flow_request.md`, `spike/flow_spike.py`, and
  `proto/flow_api_v1.proto`. Three transports Wispr uses, in fallback order:
  1. **gRPC (PRIMARY, formatted) — IMPLEMENTED (`WisprFlowProvider` + `FlowSession`).**
     Bidirectional `flow_api.v1.TranscriptionService/**TranscribeStream**` on
     `model-v31pl413.grpc.api.baseten.co:443` (TLS, grpc-swift **1.x** — 2.x floors the
     generated clients), over one process-wide keepalive'd connection
     (`FlowChannel`, mirroring Wispr's `ensureClient` + 4 s/2 s/permit-without-calls pings).
     Note the **unary** `Transcribe` RPC is Wispr's *fallback* (`makeHttpRequest`), not its
     primary — using it as the primary is what made dictation slow, see "Streaming dictation".
     Sends a protobuf
     `Request {init{metadata,preferences.vocabulary=dictionary}, context,
     payload.audio_packets=opus, commit}` — `init`+`context` once at open, then packets with
     `commit: COMMIT_FALSE` as they are encoded, then the tail with `COMMIT_TRUE`; metadata
     headers `authorization: Bearer <jwt>`,
     `baseten-authorization: Api-Key <key>`, `baseten-model-id`, `x-baseten-environment: production`,
     `disable-formatting: false`. Returns **formatted** `result.output.plaintext` (→ we use
     `llm_text || asr_text`). **Validated live end to end** — "kubectl"/"Coda" correctly spelled/cased.
     Opus via the vendored universal `COpus`/`OpusEncoder` (16 kHz mono, 20 ms / 320-sample frames).
     The Baseten `Api-Key` is read at runtime from `VOICEOP_BASETEN_KEY` or
     `~/Library/Application Support/VoiceOperator/baseten-key` and is **not committed**.
     **Where the key comes from (bundle, 2026-09-02):** it is *not* per-user and Wispr does
     not fetch it at login — it is a static constant compiled into the Wispr Flow app
     (`.webpack/main/index.js`, the config module that also holds `RT="v31pl413"`, the
     Supabase URL/anon key, and the `api.wisprflow.ai` hosts; `getRpcOptions` sends it as
     `"baseten-authorization": \`Api-Key ${Rt.Fo}\``). The per-user credential is the
     Supabase JWT in `authorization: Bearer`. On a fresh Mac, extract the bundle (see
     `CLAUDE.md`), grep for `baseten-authorization`, follow the `Fo` export to its string
     constant, and write it to `baseten-key`. Without it every dictation logs
     `stream open failed: no Baseten key … fell back to raw /llm/asr` and takes 5–10 s.
     **Surfacing the fallback (2026-09-02).** That log line was the only symptom, and a
     fresh Mac ran on the slow path for an evening before anyone read it. `StreamHealth`
     (`Core/StreamHealth.swift`) now tracks the path — `.degraded(reason:)` on a stream
     open failure, open timeout, post-commit failure, or missing key/encoder, `.streaming`
     on every successful commit — and `AudioArbiter` publishes each transition to: the
     log; a persistent menu warning line (the Secure Keyboard Entry pattern); an amber
     top-right dot on the icon in *every* state so it is seen before the next dictation;
     the key-up cue (`listeningFinishedSlow`: the normal two-tone plus a low tail, so the
     mode stays audible); `/v1/status` (`stream`, `stream_reason`); and a WARNING from
     `restart-app.sh` after each restart. The key check runs in `prewarm()` at launch.
  2. **Baseten `run_remote` HTTP (msgpack)** — decoded but rejected `input is malformed` (server
     schema not in the bundle); superseded by the gRPC path, not implemented.
  3. **`/llm/asr_audio_chunks` / `/llm/asr` (raw fallback)** — `WisprTranscriber`. gRPC falls back
     here when the Baseten key is absent or the call fails. Raw Whisper; never formats for English.
- **Why HTTP never replaces gRPC for formatted English (bundle, 2026-08-02).**
  Decoded from Wispr's `getFinalTranscriptionResult`: `/llm/asr_audio_chunks` returns
  `status: "raw_transcript"`. For English that branch falls through to raw `asrText`; the only
  follow-up formatting call is `formatNonEnglish` → `/llm/format_non_english`. Two endpoints that
  would transcribe-and-format over plain HTTP (`transcribeAndFormat` → `POST /llm/api`,
  `formatEnglish` → `POST /llm/formatting`) are **dead code** in the shipped app (definition only,
  zero call sites) — do not build on them without new bundle evidence. Formatted `llm_text` only
  arrives from the Baseten gRPC response. See `COMPATIBILITY-PLAN.md`.
- Opus params (frame size 320 / 20 ms, `OPUS_APPLICATION_VOIP`) confirmed for the chunks/gRPC paths.
