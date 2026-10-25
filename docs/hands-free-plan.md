# Hands-free in Voice Operator — migration plan (2026-10-24)

Status: **plan, under review.** Nothing here is built yet.

## Goal

Hands-free mode — always listening for a trigger word, dictating until the
speaker is finished, a conversation window after — moves out of Spaceterm and
becomes a Voice Operator (VO) service. VO does nothing hands-free until a
client registers a trigger word; Spaceterm registers `control`. Several
clients may register, each with its own word.

Spaceterm becomes a consumer: it turns hands-free on and off, draws its
buttons and gauges from VO's signals, plays cues and haptics its own way, and
runs Control on the transcripts it is handed. Its phone app carries audio to VO
through a VO iOS SDK, so **there is exactly one copy of the listening logic: in
VO, on the Mac.**

## Decisions already made

- **All listening logic lives in VO.** No speech detection, wake gating or
  endpointing on any client. A phone streams everything while hands-free is on.
  (On-device detection is not part of the design; it may be revisited only if
  battery is measured to be a problem.)
- **The trigger word is returned in the transcript.** VO does not strip it; the
  client does if it wants to.
- **Cues and haptics are signals.** VO says *what happened* (`dictationStart`,
  `notWakeWord`, …, with a suggested haptic); the client decides how it sounds
  or feels.
- **Gauges are data points, not frames.** VO sends when the quiet began, the
  patience deadline, and each Smart Turn answer with its threshold; clients
  animate locally.
- **"Let me turn this off" belongs to VO**, as does `<trigger>, shutdown`: they
  end the session in a hands-free way, and VO tells the client the user ended it
  by voice. Spaceterm then sends Control away itself.
- **One active session per client.** Turning hands-free on somewhere ends the
  client's previous session (with a signal to it).
- **No fallback to the Mac's microphone.** A phone session lost past its resume
  window simply ends; the user turns hands-free on at the Mac if they want it
  there. Nothing starts listening somewhere unexpectedly.
- **The tuning file is dropped.** Spaceterm's defaults become VO's constants;
  the filler-word list (`hmm`, `um`, …) is a built-in default.
- **Naming.** "Hands-free" means this always-listening mode. VO's double-tap Fn
  lock is renamed **transcribe lock** (code, menu, logs, DESIGN.md).
- **The iOS SDK owns the microphone and all playback.** Echo cancellation needs
  the voice and the microphone on one voice-processing engine, so speech plays
  through the SDK. The client mixes its own audio (cues) in through the SDK:
  one player node only — a second `AVAudioPlayerNode` on that engine is what
  made Spotify go silent under the microphone on 2026-10-13
  (`NativeMicrophone.swift`, "Hands-free's tones"). Client audio is mixed in
  software into that one stream, and VO's speech is ducked under it as asked.
- **SDK language: Swift**, a Swift package the Spaceterm iOS shell links. The
  page reaches it through the existing native bridge.

## What exists today (for orientation)

Spaceterm:
- `src/mobile/hands-free.ts` (876 lines), `wake-listener.ts` (`SpeechGate`,
  `UtteranceEndpointer`, `WakeListener`, `EnergyScorer`, `DEFAULT_TUNING`),
  `speech-detector.ts` (Silero VAD in ONNX web), `held-microphone.ts`,
  `hands-free-mode.ts`, `ready-cue.ts`, `cues.ts`, `control-tones.ts`,
  `HandsFreeButton.tsx`. Runs on the phone and, as the same code, in the
  Electron renderer on the Mac (`desktop-hands-free.ts`).
- `src/shared/control-shutdown.ts` — the shutdown phrases.
- Server: `hands-free.ts` (wake/speech check via VO, filler words, tuning),
  `turn-detector.ts` (Smart Turn v3.2 + Whisper features, onnxruntime-node),
  `voice-record.ts` (`voice-decisions.jsonl` + `voice-clips/`),
  `remote-dictation.ts` (phone audio → VO `/v1/transcriptions`, turn checks),
  `remote-speech.ts` (VO `/v1/synthesize` → phone playback, offsets).
- iOS: `NativeMicrophone.swift` (1615 lines: session category and mixing rules,
  voice processing, the one player, cues, pending tone, config-change restarts).

VO:
- `WakeWordCheck` (Apple `SpeechTranscriber`, macOS 26) behind `/v1/wake-word`.
- `RemoteTranscriptionManager` behind `/v1/transcriptions`.
- `SubscriberRegistry` / `SubscriberSocket`: saved registrations, VO pushes
  newline JSON to a client's socket. One-way.
- `AudioRecorder` with an always-on mode; `AudioArbiter` owns dictation;
  `TranscriptionProvider`/`TranscriptionLeg`; `haltSpeech(heardUntil:)`;
  FluidAudio (Silero VAD streaming available); vendored libopus.

## The split

| VO (Mac) | iOS SDK (phone, VO's code) | Client (Spaceterm) |
|---|---|---|
| Speech detection (Silero via FluidAudio), the quiet-before rule, trigger check against all registered words, routing | Audio session, mic capture with echo cancellation, config-change recovery | Register trigger word; turn hands-free on/off and choose where (Mac or a phone) |
| Conversation window, shutdown phrases | One player: VO speech + client audio mixed in software, ducking | Buttons and gauges, animated locally from data points |
| Endpointing: silence patience + Smart Turn | Streaming with sequence numbers, ack, resume buffer | Play cues / haptics for VO's signals |
| Transcription via the user's provider, fed from the start of speech | Transport-agnostic: the app supplies send/receive bytes | Strip the trigger word; run Control on transcripts |
| Stand-aside rules (a Fn dictation wins) | | Drop its speech job on a cut-in signal (`DELETE …?heard_until=`) |
| Decision record, incognito gating | | Relay the SDK's bytes to VO opaquely (phone case) |

## Protocol (outline — to be specified in DESIGN.md before code)

**Connection.** VO listens on a Unix socket in its Application Support dir. A
client opens and **holds** a connection; its registration lives exactly as long
as the connection (unlike today's saved subscribers, which would otherwise make
VO listen at login with Spaceterm closed). Versioned hello:
`{type: hello, protocol: 1, client: "spaceterm", trigger: "control"}`. A
duplicate trigger word is refused.

**Client → VO:** `hands-free {on: true, source: "mac" | {stream: <device id>}}`,
`hands-free {on: false}`; later, `hold-window` heartbeats (Control thinking —
out of scope for the port, room left for it). Stream sessions additionally
carry `audio {seq, pcm}` and `playing {speaking: bool}` from the SDK (until VO
speech plays through the SDK natively, see phase 5).

**VO → client:** `phase {listening | checking | hearing | sending | off, why}`,
`conversation {open, closesAt}`, `quiet {since, patienceMs}`,
`turn {p, threshold}`, `sampling {threshold | null}`,
`signal {name, haptic?}` (`ready`, `checkingStart/Stop`, `dictationStart`,
`dictationEnd`, `notWakeWord`, `conversationClosed`, `shutdown`, `error`),
`cut-in {at}` and `duck {on}`, `transcript {text, trigger, interrupted}`
(`text` empty when nothing followed the trigger — the client still hears of it,
as Control does today), `session-ended {why: replaced | shutdown | lost | off}`.
Timestamps are wall-clock ms; phone sessions resolve against the stream's own
sequence clock.

**Phone transport.** VO stays loopback-only. Spaceterm's server opens one VO
connection per phone session and pipes the SDK's frames through its existing
phone WebSocket without parsing them. Audio starts as 16 kHz s16le (≈115 MB/h);
opus (≈7 MB/h; VO already vendors libopus) is a later step.

**Dropouts.** The SDK keeps the last 60 s of audio, numbered; VO acks; on
reconnect the SDK resumes from the last ack and VO processes the backlog late.
A stall longer than the resume window (proposed 10 s; past it, the gap is
treated as silence-then-loss) ends the session (`session-ended {why: lost}`).
This is better than today, where a mid-dictation blip loses the dictation
(audio sent while disconnected is dropped; the server cancels the phone's
dictations on disconnect).

## Phases

Each phase leaves both apps working.

0. **Rename** VO's Fn double-tap/⌘ lock to "transcribe lock". Independent.
1. **Connection + registration** in VO (held socket, hello, trigger words,
   sessions, signals plumbing), with a CLI live-test (`--hands-free-test`).
   Spaceterm server registers `control` and relays VO's events to its clients.
2. **Mac hands-free in VO, silence-only endpointing.** Port the listener state
   machine (`SpeechGate`, `WakeListener`, `UtteranceEndpointer`, conversation
   window, shutdown phrases, filler words) to Swift on `AudioRecorder`'s
   always-on capture, Silero from FluidAudio. Wake check is `WakeWordCheck` with
   all registered words. Transcription through `TranscriptionProvider`, fed the
   backlog from speech start then live. Fn dictation preempts. Decision record
   (`hands-free/decisions.jsonl` + clips, newest 400) behind `Incognito`.
   Spaceterm's Mac button switches to VO; `desktop-hands-free.ts` removed.
   **Regression check:** replay Spaceterm's 400 kept clips and
   `voice-decisions.jsonl` through VO's listener and compare decisions.
3. **Smart Turn in VO.** Run the same `smart-turn-v3.2-cpu.onnx` (pinned URL and
   hash, as Spaceterm does) with ONNX Runtime's Swift package; port
   `whisperFeatures` and its reference tests from `turn-detector.test.ts`.
4. **iOS SDK + phone through VO.** Swift package: engine and session handling
   moved from `NativeMicrophone.swift`, one player with software mixing, stream
   with ack/resume, transport hook. VO accepts stream sources. Spaceterm's phone
   hands-free switches to the SDK; Control's voice is still synthesised by
   Spaceterm (`RemoteSpeech`) and played through the SDK's client-audio API,
   flagged as speech so ducking, `playing` and cut-in work.
   The phone's **button dictation** (not hands-free) must also go through the
   SDK, since the SDK now owns the microphone: the SDK exposes a manual
   start/stop dictation on the same stream.
5. **VO speech to an SDK device.** A speech job may target a connected device;
   VO synthesises and the SDK plays it, so job status, `character_offset` and
   `heard_until` work identically on Mac and phone. `RemoteSpeech` and the
   client-reported `playing` go away.
6. **Cleanup.** Spaceterm deletes `hands-free.ts` (both), `wake-listener.ts`,
   `speech-detector.ts`, `turn-detector.ts`, `voice-record.ts`, the tuning
   plumbing, `wake-word-check`/`dictation-turn-check` messages and the
   onnxruntime dependencies. VO keeps `/v1/wake-word` for one release, then
   removes it.

## Open questions for review

- **Mac without a headset.** Spaceterm's Mac hands-free assumes a headset. VO
  plays Control's voice; through built-in speakers the microphone hears it and
  the conversation window would take it for the user. Stand aside while VO's own
  speech plays on non-headphone outputs? (VO's `NarrationDucker` already runs a
  Voice Processing I/O graph during speech — and DESIGN.md notes that a plain
  input stream alongside it distorts all output on the EPOS dongle.)
- **Packaging the SDK.** VO's `Package.swift` is macOS-only and pulls grpc,
  FluidAudio and libopus. A separate iOS product in the same package, or a
  second package? The wire-protocol types should be shared by both sides.
- **Two Spaceterm instances** (SpacetermBar can start a second client) both
  registering `control`: refuse the second, or last wins?
- **Incognito.** Does turning it on end hands-free sessions, or only stop the
  record and the provider's network calls as today?
