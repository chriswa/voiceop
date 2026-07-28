# Voice Operator — Design

## Current scope (2026-07-27)

Voice Operator is now deliberately a small dictation and local speech service.
It no longer watches Claude transcripts, summarizes agent work, assigns names or
voices to agents, or pushes agent-update state to Spaceterm.

### Local speech API

At launch the app binds a loopback TCP listener on a kernel-assigned ephemeral
port and atomically writes `~/Library/Application Support/VoiceOperator/speech-service.json`:

```json
{"version":1,"port":58432,"pid":12345}
```

There is no bearer token: this is a same-user, loopback service. Clients read
the discovery file (and re-read it after a connection failure).

| Method | Path | Meaning |
| --- | --- | --- |
| `POST` | `/v1/speech` | Queue `{text, voice?}` and return `202` + job id. |
| `GET` | `/v1/speech/{id}?wait=0..30` | Inspect or long-poll a job. Pending is `202`; complete is `200`; a dictation barge-in is `409`; cancellation/mute flush is `410`; synthesis failure is `500`. |
| `DELETE` | `/v1/speech/{id}` | Halt immediately if audible, otherwise retract it. |
| `GET` | `/v1/voices` | Return the currently available external Kokoro voices. |

Speech is FIFO. Input is split using Foundation sentence boundaries. The
`character_offset` in every terminal response is a zero-based, end-exclusive
Unicode-scalar offset into the original input and advances only after an entire
sentence completed. The current sentence plus the next two are synthesized/
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

### English transcription preference (2026-07-27)

The current Wispr Flow bundle's `transcribeOpenAIAudio` derives a single
selected language and sends it as the string `language` in `/llm/asr` (for
English, `"en"`). Voice Operator supplies `"en"` for dictation. Its historical
gRPC replica has an unresolved protobuf `Language` enum and therefore cannot
reliably send that preference; when a language is requested it deliberately
uses the confirmed raw `/llm/asr` path rather than silently language-detecting.
This trades server formatting for correct language selection until the current
formatted Flow request is fully ported.

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
- **Dictation**: hold-to-talk + double-tap-to-toggle, transcription pasted into the focused
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
  silence detection. Flow also caps a dictation at 20 min (warning at 19). We replicate the
  full model: the recorder converts to 16 kHz s16le live in the tap, the arbiter transcribes
  each full 28 s chunk *while recording continues* (sequential, one in flight — see
  `AudioArbiter.pumpLiveChunks`), and only the short tail is transcribed at stop, so paste
  latency is flat regardless of dictation length. `WisprTranscriber.transcribe` also chunks
  any >28 s WAV it's handed (retries of stored clips take that path).
- **Silence never drops audio (decoded 2026-07-15).** Flow's send loop pushes *every*
  captured packet through transcription — there is no per-chunk volume/silence gate in the
  send path. Its silence tracking (`silentStreamStreakMs`, `longestSilentStreakMs`,
  `silenceAccruedMs`, `numConsecutiveSilentFrames`) drives only (a) **auto-stop** — a 30 s
  silent streak / 10 min accrued-silence "arm" ends the recording (`RecordingStoppedSilence`,
  `noteAutoStop("silence")`) — and (b) **dead-mic watchdogs** (`firstFrameWatchdog`,
  `silentWatchdog`). Audio quality (`SNR<5dB`, `volume<-70dB`, `alignment<0.15`) is judged
  *after* transcription and only raises a `poorAudioQuality` user notice; it never discards
  text. We mirror this: `pumpLiveChunks` transcribes every chunk, and the single silence
  decision is the whole-clip peak/RMS gate in `endDictation` (i.e. skip only when the entire
  recording — every chunk — was silent). An earlier per-chunk gate that dropped individual
  28 s slices judged in isolation lost soft words and boundary-split words and was removed.
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

### Mute-during-dictation — CoreAudio device mute, gated on now-playing
- On `RecordingStarted`: `shouldMuteAudio: 1` → Volume Manager checks now-playing; if media is
  playing it saves state and `Set system mute state to true for device <id>` (the default
  output device, `kAudioDevicePropertyMute`). If nothing is playing: `Skipping mute`.
- On stop: restores, tracking `wasPreviouslyMuted` so we never unmute audio the user had muted.
- It is a **system output-device mute**, not a Spotify-specific pause.

### Trigger key
- Wispr uses Fn (keycode 63) via a "Keyboard Service" push-to-talk (`Ptt action down`).
- **Ours**: default to **Right Shift (keycode 60)** during development via a `CGEventTap` on
  `flagsChanged`, configurable, so Wispr Flow (still on Fn) keeps working in parallel until we
  retire it. Migrate to Fn later. (macOS "double-tap Fn" dictation already disabled by user.)

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
Hotkey/                                CGEventTap; Right Shift now -> Fn later; hold + double-tap
MenuBarUI/                             status states + Pause toggle
```

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

- **Milestone C — SHIPPED: formatted gRPC dictation (Wispr parity) (2026-07-08).**
  Full ground-truth decode from the Wispr Flow app bundle (`serializeFlowRequest` + the
  `flow_api.v1` protobuf), captured in `spike/flow_request.md`, `spike/flow_spike.py`, and
  `proto/flow_api_v1.proto`. Three transports Wispr uses, in fallback order:
  1. **gRPC (PRIMARY, formatted) — IMPLEMENTED (`WisprFlowTranscriber`).** Unary
     `flow_api.v1.TranscriptionService/Transcribe` on `model-v31pl413.grpc.api.baseten.co:443`
     (TLS, grpc-swift v2). Sends a protobuf `Request {init{metadata,preferences.vocabulary=dictionary},
     context, payload.audio_packets=opus, commit}`; metadata headers `authorization: Bearer <jwt>`,
     `baseten-authorization: Api-Key <key>`, `baseten-model-id`, `x-baseten-environment: production`,
     `disable-formatting: false`. Returns **formatted** `result.output.plaintext` (→ we use
     `llm_text || asr_text`). **Validated live end to end** — "kubectl"/"Coda" correctly spelled/cased.
     Opus via the vendored `COpus`/`OpusEncoder` (16 kHz mono, 20 ms / 320-sample frames).
     The Baseten `Api-Key` is read at runtime from `VOICEOP_BASETEN_KEY` or
     `~/Library/Application Support/VoiceOperator/baseten-key` and is **not committed**.
  2. **Baseten `run_remote` HTTP (msgpack)** — decoded but rejected `input is malformed` (server
     schema not in the bundle); superseded by the gRPC path, not implemented.
  3. **`/llm/asr_audio_chunks` / `/llm/asr` (raw fallback)** — `WisprTranscriber`. gRPC falls back
     here when the Baseten key is absent or the call fails. Raw Whisper; never formats.
- Opus params (frame size 320 / 20 ms, `OPUS_APPLICATION_VOIP`) confirmed for the chunks/gRPC paths.
