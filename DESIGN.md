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
`/v1/restart`.

| Method | Path | Meaning |
| --- | --- | --- |
| `POST` | `/v1/speech` | Queue `{text, voice?}` and return `202` + job id. |
| `GET` | `/v1/speech/{id}?wait=0..30[&since=N]` | Inspect or long-poll a job. Pending is `202`; complete is `200`; a dictation barge-in is `409`; cancellation/mute flush is `410`; synthesis failure is `500`. |
| `DELETE` | `/v1/speech/{id}` | Halt immediately if audible, otherwise retract it. |
| `GET` | `/v1/voices` | Return the currently available external Kokoro voices. |
| `GET` | `/v1/status` | `{version, build, commit, pid, status, dictating, restart}` — which build is running and what it is doing. `status` is the menu-bar state (`idle`, `listening`, `transcribing`, `speaking`, …); `restart` is `none`, `pending`, or `restarting`. |
| `POST` | `/v1/restart` | Ask the app to relaunch itself. `200 {"restart":"restarting"}` when idle; `202 {"restart":"pending","reason":"dictating"}` when a dictation is in flight — it fires once that dictation has been pasted. Idempotent. |

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
UTF-16 offset into the original input. While a job runs it advances a whole
sentence at a time, since that is the granularity at which the queue knows
anything. A job a listener *interrupted* reports where the voice actually
stopped, to the word: the reading overlay's timings (`SpokenNarration`) locate
the word being spoken at the moment of the halt, and its end is added to the
start of the sentence it was in. A word counts as heard once it has started, so
the offset matches what the overlay had lit up. Without word timings — they
resolve asynchronously, and a sentence can be interrupted before its own
arrive — the offset falls back to the last completed sentence. The current
sentence plus the next two are synthesized/
cached ahead of playback to avoid sentence-boundary gaps. Dictation halts the
current sentence and holds the queue until transcription finishes. Muting
immediately halts/cancels every live or queued job; new queue attempts receive
`503 speech_muted`.

### Dictation and command mode

Fn dictation still transcribes and pastes into the frontmost app. Ctrl+Fn is
command mode: the app identity is captured when recording stops. If it is
Spaceterm (`com.spaceterm.app`), Voice Operator sends the verbatim transcription
as newline-delimited JSON to `~/.spaceterm/hooks.sock`:

```json
{"type":"voice-command","text":"<transcription>"}
```

Spaceterm owns the meaning of that event. Any other focused app records the
command transcription but plays the unrecognized/error cue and performs no
action. Clipboard speech and clipboard summarization remain user-facing tools;
the latter is an independent Haiku clipboard utility, not transcript tracking.

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
  hands-free), transcription pasted into the focused
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
- **Streaming dictation (2026-08-04).** The trigger key going down starts three things at
  once: the microphone, the duplex gRPC stream, and a 100 ms upload pump
  (`AudioArbiter.pumpAudio`) that opus-encodes each new slice of captured PCM and pushes it up
  the open stream. Key-up sends the tail with `commit: TRUE` and closes the request stream, so
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
  closes, and a second press inside it locks hands-free. Audio we turn out not to need is free;
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
- **⌘⌃V re-pastes** the last insertion; **⌘⌃⇧V undoes** it — one backspace per character of
  `AudioArbiter.lastInsertion`, through the same serial queue as typing (so an undo can never
  interleave with an insertion still going out), then the falling mirror of the inserted cue. The
  insertion is marked not-live *before* the backspaces go out, so a second undo is a no-op even if
  it lands while the first is still typing; the text is kept, so ⌘⌃V can put it back. The chords
  fire on key-down, so the undo first waits (up to 2 s) for the user to release the modifiers: our
  events carry empty flags, but an app that reads the hardware modifier state instead would see
  each Delete as ⌘⌫. `Chord` matches Shift rather than ignoring it, which is what lets ⌘⌃V and
  ⌘⌃⇧V share a keycode — and stops a stray Shift aliasing any other chord onto its handler.

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

#### Locking hands-free mid-dictation — ⌘ while holding the trigger (2026-08-18)

There are three ways to run a dictation, and the third exists because the choice
between the first two has to be made *before* you know how long you will talk:

1. **Hold** Fn, speak, release — push-to-talk.
2. **Double-tap** Fn, speak, tap Fn — hands-free.
3. **Hold** Fn, speak, **tap ⌘ while still holding**, release Fn, keep speaking,
   tap Fn to end — a push-to-talk promoted to hands-free without interrupting it.

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
2. **Shift is not cycled on key-down.** During a hands-free locked dictation the
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
no reverse-engineering:

- `POST {base}/synthesize`, `Content-Type: application/json`,
  body `{ "text": <string ≤5000>, "voice": <voice id>, "speed": <0.5–2.0, default 1.2> }`.
  Base URL defaults to `http://localhost:56841`, overridable via `$VOICEOP_KOKORO_URL`.
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
wall-clock sentence anchor. Toggle: menu **Word Overlay** (`OverlayPreferences.wordOverlayEnabled`,
default on).

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

## Voice commands (command mode)

Command mode (hold **Ctrl** with the dictation trigger) routes the transcript to
`AppCoordinator.handleVoiceCommand` instead of pasting it. Recognition is a
hand-written tokenizer (not an LLM classifier). Grammar is **name-first** — an
optional leading call-sign, then either a reserved word or free text:

    [name] repeat | focus | skip        (a lone reserved word)
    [name] <anything else>              (free text → an aside)

| Command | Example | Effect |
|---|---|---|
| `[name]` | `Apollo` | raise the agent's spaceterm surface (a lone `focus` does the same) |
| `[name] repeat` | `Apollo repeat` | replay the agent's latest update (free, from cache) |
| `[name] <message>` | `Apollo what was that second file?` | an **aside**: question the summarizer — a multi-turn Haiku call over the original context + what was spoken + the running aside thread (`ClaudeSummarizer.ask`). Use it to go deeper too, e.g. `Apollo, more detail` |
| `skip` | `skip` | global: drop the clip playing now so playback advances |

Rules:
- **Name = a known call-sign.** The first token is a name only if it resolves to a
  currently-active agent (`registry.claudeSession(forName:)`, homophones included).
  Otherwise there is no name and the whole utterance targets the **last-referenced**
  session (the last agent that spoke). `skip` is global and ignores any name.
- **Bare call-sign = focus.** A name with nothing after it (`"Apollo"`) raises its
  surface — the quickest way to focus. `focus` remains as an explicit synonym.
- **Everything that isn't `repeat`/`focus`/`skip` is an aside.** A lone reserved
  word is that command; any other words (with or without a leading name) are sent
  as a free-text question to the summarizer. So `Apollo <question>` asks about
  Apollo's latest update, and a nameless `<question>` asks about the last agent's.
- **Free-text payload.** The aside message is taken from the *original* transcript
  (casing/punctuation preserved), with the leading call-sign — if any — dropped.
- **`aside` behaviour.** It's a genuine back-and-forth that MAY repeat on request,
  go deeper, or answer a specific question — asking it for "more detail" subsumes
  the old dedicated `more details` verb. Each aside is stored on the target
  `TTSHistoryEntry` (`asks`: alternating user/assistant `Turn`s) and is spoken as a
  new entry, so asides / `repeat` chain off the answer.
- **Asides are read-only.** They question the low-context Haiku summarizer, which
  only knows the turn it summarized — they do *not* reach the real Claude Code
  session. A future **`send`** verb (not yet built) is reserved for pushing a
  message into the canonical session via spaceterm.
- **Unrecognized** only when there's nothing to act on — an empty transcript, or an
  aside/command with no target (unknown name and no last agent). Those play the
  `unrecognized` cue and are not pasted.

New argument-taking commands should keep this `[name] <verb> [args]` shape so the
optional-name peel and last-referenced fallback apply uniformly.

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
  1. **gRPC (PRIMARY, formatted) — IMPLEMENTED (`WisprFlowTranscriber` + `FlowSession`).**
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
