# Hands-free in Voice Operator — migration plan (2026-10-24)

Status: **phases 0–4 and 6 built (2026-10-24); phase 5 built 2026-10-25.**
What was built, where it differs from the plan:

- VO: `Sources/VoiceOperator/HandsFree/` (DESIGN.md "Hands-free" has the
  protocol). Live-tested with `--hands-free-test` (a stream, end to end) and on
  the Mac's microphone (audio flows; speech untested there — the lid was
  closed, so the microphone gave digital silence, which hands-free now reports).
- SDK: `sdk/VoiceOperatorKit` — `VoiceOperatorHandsFree` (the stream client,
  tested on macOS, including a real transcription across a dropout and resume:
  `VOICEOP_SDK_SPEECH_TEST=1`) and `VoiceOperatorAudio` (Spaceterm's
  `NativeMicrophone` engine, moved; iOS 17). Builds for the simulator; not yet
  run on a device.
- Spaceterm: the server registers `control` and relays phone streams
  (`voice-operator-hands-free.ts`); the page follows VO's messages
  (`src/mobile/hands-free.ts`); the listener, Silero, Smart Turn, the voice
  record, the tuning file and onnxruntime are gone. Audio is still PCM (opus is
  a follow-up), and the phone's button dictation still goes through the page's
  own path (`/v1/transcriptions`), on audio the SDK engine hands the page.
- Phase 5 (VO speech to a device), 2026-10-25: VO keeps the job
  (`DeviceSpeech`, DESIGN.md "Speech on a device") and Spaceterm's
  `RemoteSpeech` is gone. The SDK has the speaker client (`SpeechDevice`,
  `SpeakerSession`), but Spaceterm's phone page speaks the protocol itself:
  it still chooses between the app's engine and the page's own audio for each
  job, as before, and runs in a browser too. The SDK's engine still reports
  `playing` itself.
- VO's `/v1/wake-word` stays until no Spaceterm build uses it.

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
| Speech detection (Spaceterm's Silero ONNX model, 32 ms frames), the quiet-before rule, trigger check against all registered words, routing | Audio session, mic capture with echo cancellation, config-change recovery | Register trigger word; turn hands-free on/off and choose where (Mac or a phone) |
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
2. **Mac hands-free in VO, silence-only endpointing.** Pre-work: the second
   microphone consumer and the open-mic stale-engine fix (see "Decisions from
   review"). Port the listener state machine (`SpeechGate`, `WakeListener`,
   `UtteranceEndpointer`, conversation window, shutdown phrases, filler words)
   to Swift on that consumer, Silero on ONNX Runtime. Wake check is `WakeWordCheck` with
   all registered words. Transcription through `TranscriptionProvider`, fed the
   backlog from speech start then live. Fn dictation preempts. Decision record
   (`hands-free/decisions.jsonl` + clips, newest 400) behind `Incognito`.
   Spaceterm's Mac button switches to VO; `desktop-hands-free.ts` removed.
   **Regression check:** replay Spaceterm's 400 kept clips through the wake
   check and compare with `voice-decisions.jsonl`.
3. **Smart Turn in VO.** Run the same `smart-turn-v3.2-cpu.onnx` (pinned URL and
   hash, as Spaceterm does) on the ONNX Runtime brought in by phase 2; port
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

## Decisions from review

- **Silero runs as Spaceterm runs it**, not through FluidAudio. FluidAudio's
  CoreML Silero takes 256 ms chunks (`VadManager.chunkSize` 4096); every
  hands-free constant is built on 32 ms frames (start 0.5 / stop 0.35, two
  start frames, five hangover frames, `wordMinMs` 250). VO runs
  `silero_vad_16k_op15.onnx` (512-sample frames, 64-sample context, state
  `[2,1,128]`) on ONNX Runtime's Swift package, which therefore arrives in
  phase 2, not 3. Models download at prewarm, never at first "on".
- **Hands-free reads the microphone through its own consumer.** The always-on
  tap drops every buffer outside a recording (`AudioRecorder.handleTap`) and a
  second `start()` throws, so hands-free never calls `recorder.start()`: it gets
  a second, recording-independent consumer feeding an 8 s ring buffer. A Fn
  dictation then records normally beside it, and hands-free stands aside while
  it does. Hands-free forces the hold on (overriding the AirPods-only
  preference and the stand-down limiter) and is told when the hold gives up.
  `replaceEngineIfStale` only runs while the mic is closed; with hands-free
  holding it open on AirPods, the post-TTS stale-engine failure needs a fix
  that works with the mic open. This is pre-work for phase 2.
- **A hands-free dictation is not an `AudioArbiter` dictation.** That path
  halts speech, mutes output and interrupts the speech job the moment it
  starts, which is right for a key press. Hands-free still cuts Control off,
  as today, but only once the check says the speech was for it (the trigger
  word, or words in the conversation window): Control is ducked while it is
  decided, cut off afterwards as of when the user began, and carries on if it
  was nothing. Hands-free builds its
  own session on `TranscriptionLeg`, as `RemoteTranscriptionManager` does: it
  holds cooperative restarts, mutes nothing, fires no `voice-dictation` event.
  VO sends `phase hearing` at its start and the transcript at its end; Spaceterm
  maps those to Control's "user is speaking" hold (today's `forControl`).
- **VO takes over Spaceterm's judging**, not only `WakeWordCheck`: the trigger
  words, the filler list, `wakeFreeShutdown` (start-of-phrase → watch the whole
  utterance), "lemme". One `SpeechTranscriber` analyzer is kept warm while a
  session is on.
- **Incognito ends hands-free.** Turning it on ends every session
  (`session-ended {why: incognito}`); `hands-free on` is refused while it is on.
  (Today the checks are already refused, so the microphone listens for nothing.)
- **Phone timing.** VO converts stream time to Mac wall time (arrival minus the
  unprocessed backlog) for `heard_until`, capped as today (10 s). A gap over
  ~2 s resets the listener (`listener.resume()` semantics): late audio is
  transcribed if a dictation was already under way, but never starts a new one
  or cuts Control off retroactively.
- **Audio is opus from the start of phase 4**, in binary frames — raw base64
  PCM would be ~340 kbit/s through Spaceterm's server event loop.
- **The SDK is a separate Swift package** (VO's `Package.swift` links libopus
  with `unsafeFlags`, which SwiftPM refuses in a remote dependency). A small
  platform-agnostic protocol target is shared, VO depending on it by path.
- **Mac on speakers:** while VO's own speech plays on a non-headphone output,
  hands-free stands aside (plus the playback tail); voice cut-in works on
  headsets only — today's assumption, made explicit. VO's speech now also holds
  the conversation window open on the Mac, which it cannot do today.
- **A duplicate trigger word is refused**, keyed on the held connection, so a
  test instance can never take `control` from the real one.
- **Between phases 2 and 6**, Spaceterm picks one source per device, so VO's Mac
  hands-free and the old phone path never both answer the same "control". The
  empty-text and `interrupted` semantics of today's `receptionist-hands-free`
  are kept by `transcript {text: "", interrupted}`.
- **Phase 1 is real infrastructure:** VO has no Unix-socket server (subscriber
  sockets are one connection per message; the HTTP service is `NWListener` TCP).
  Framing, duplex and audio backpressure are built there.
- **The SDK carries over `NativeMicrophone.swift`'s rules** as a checklist:
  pending tone only on an idle player, cut by a cue or speech; headphones mean
  no voice processing, duck-others and `echoFree`; echo-cancelled speech volume
  compensation; Spotify ducking while dictating (now driven by VO's `phase`);
  the half-second session release before hands-free; the `hands-free-echo`
  record; the 48 kHz wide-Bluetooth zero-audio rule.
- **Tests:** the listener is pure Swift, with synthetic-frame tests mirroring
  `wake-listener.test.ts` and `hands-free.test.ts`. The 400 kept clips replay
  the wake check and Smart Turn only — they are 1 s and 8 s snippets, not
  continuous audio.

- **No recorded baseline.** Start/end-of-speech drift from the port is found
  and fixed in use, after the fact.
- **Parakeet's whole-clip transcription is fine.** It transcribes only at
  commit (`ParakeetSession.send` just appends), but measured on this Mac it
  takes ~1.5% of the audio's length (78 s → 1.2 s, 25 s → 0.3 s), so even a
  long hands-free monologue waits a few seconds at most. No streaming needed.

## Open questions as first written (resolved above)

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
