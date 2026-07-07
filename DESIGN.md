# Voice Operator — Design

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
- **Cartesia audio cache**: every synthesized stream cached ≥1 day, keyed by (text, voice),
  replayed for free.
- **Menu bar UI**: live status (idle / listening / transcribing / pasting / speaking), and a
  quick **Pause** toggle (for meetings).

Out (deferred):
- Command mode. Directing a reply to a named surface (tracked in the name registry design,
  but not wired yet). Historical replay UI. On-device STT/TTS. Reimplementing Wispr login.
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
  AudioCache          Cartesia PCM cached by (text, voiceId) hash, >=1 day, free replay
Transcriber/  (protocol Transcriber)   WisprTranscriber today (WS + /llm HTTP); LocalWhisper later
Speaker/      (protocol Speaker)       CartesiaSpeaker (ports cartesia-read streaming + tones)
Inserter/                              Swift paste helper (lazy clipboard + Cmd-V + restore + AX ctx)
ClaudeWatcher/                         ports transcript-reader.py: tail, Haiku-summarize, spaceterm sock
Hotkey/                                CGEventTap; Right Shift now -> Fn later; hold + double-tap
MenuBarUI/                             status states + Pause toggle
```

**`AudioArbiter` invariant** (the reason this app exists): dictation-start → halt current TTS
(re-cue from start) + mute output + block queue; dictation-end (+delay) → unmute + drain queue.
This fixes "a TTS update arrives while I'm dictating and I miss it."

**Provider boundaries** so Wispr and Cartesia are swappable: `Transcriber` (audio→text),
`Speaker` (text→audio), each behind a protocol with the vendor client fully contained.

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
- **Phase 3 — Speaker + ClaudeWatcher + AudioArbiter.** Cartesia TTS with cache, transcript
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
- **Name/voice registry:** ✅ `NameVoiceTable` (82 gender-aligned pairs; call-sign gender
  matches the Cartesia voice's reported gender) + `NameVoiceRegistry` (sticky,
  no active reuse, idle TTL) with passing unit tests.
- **Phase 3 (TTS half):** ✅ built + validated. `CartesiaSynthesizer` (`/tts/bytes`, native),
  `AudioCache` (≥1-day WAV cache, free replay), `SpeechPlayer` (haltable/awaitable),
  `TTSEngine`, and the `AudioArbiter` TTS queue with **barge-in re-cue** (dictation halts +
  re-queues the interrupted utterance from the start). `ClaudeWatcher` = `TranscriptParser`
  (unit-tested) + `ClaudeSummarizer` (Keychain OAuth → Haiku) + `TranscriptWatcher` (tail,
  mute headless/bg — orphaned Bash tasks whose completion notification the harness never
  persisted are resolved by probing whether anything still holds the task's `.output` file
  open — sticky name/voice, idle TTL) + `SpacetermSocket` (tts-speaking events).
  All three external integrations validated with one live call each:
  `--asr-test`, `--tts-test`, `--summarize-test`.
- **Phase 4 (retire Wispr + transcript-reader.py, move to Fn):** ⏳ pending live use.
- **Blocked on user:** macOS Accessibility + Microphone grants to verify the full live loop
  (dictation paste + Claude narration) in the real app bundle.

## Open items (remaining spike milestones)
- **Milestone B** — `wss://api.wisprflow.ai/…/ws` streaming: exact path + handshake (auth via
  header vs query param) + per-message JSON schema (opus `audio_chunks` up, `partial_transcript`
  down). Lower priority now that HTTP `/llm/asr` is proven sufficient for v1.
- **Milestone C** — the richer "flow request" (`serializeFlowRequest`: `access_token`, `audio`/
  `audio_packets`, `pipeline`, `context{app, ax_context, ocr_context, dictionary_context,
  user_*}`) → `POST /llm/asr_audio_chunks`, for dictionary/proper-noun/context-aware formatting
  beyond raw Whisper. Decode `pipeline` steps + minimal viable `context`.
- Opus params (frame size, bitrate) for the WS/chunks paths.
