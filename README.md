# Voice Operator

A macOS menu-bar app for talking to your Mac and having it talk back, with
everything kept on the Mac by default:

- **Dictation into any app.** Hold Fn and speak; the transcript is pasted where
  your cursor is. Transcribed on the Mac by default (Parakeet).
- **Text to speech.** Reads the clipboard aloud in a local Kokoro voice, with a
  word-by-word overlay and speed and rewind keys.
- **A local speech service for other apps.** Over a loopback HTTP API and a Unix
  socket, your own software can queue speech and be told how far the listener
  got when they interrupt it, transcribe audio captured elsewhere, receive
  command dictations (Ctrl+Fn), and run **hands-free**: always listening for its
  own trigger word, with a conversation window, end-of-turn detection and
  barge-in.
- **An iOS SDK** (`sdk/VoiceOperatorKit`) that gives an iPhone app the same
  hands-free, streaming its microphone to the Mac.

One audio coordinator sits under all of it, so dictation always stops speech,
other audio is muted while you dictate and turned down while it speaks, and a
restart waits until nobody is talking or listening.

[Spaceterm](https://github.com/chriswa/spaceterm) is its first client: its
Control assistant speaks through Voice Operator, takes command dictations, and
uses hands-free on the Mac and through its iPhone app.

`DESIGN.md` has the architecture and every API in detail.

## Install

Runs on the **latest macOS release** on Apple Silicon Macs.

1. Download `VoiceOperator.zip` from the [latest release](../../releases/latest).
2. Unzip it and drag **Voice Operator.app** into `/Applications`.
3. Open it. It's signed and notarized by Apple, so it launches without warnings
   (on first open macOS confirms it was downloaded from the internet — click
   **Open**).

## First-run permissions (required)

The app needs three macOS grants (System Settings → Privacy & Security):

1. **Microphone** — to record dictation.
2. **Accessibility** — to post ⌘V for pasting.
3. **Input Monitoring** — to receive the trigger key (without it, a keyboard tap
   gets its keycodes zeroed, so the trigger never fires).

The app prompts for all three on launch and installs the key tap the moment the
grants land (no relaunch needed).

## Dictation

Two modes, chosen by whether **Control** is held when you start:

- **Fn (🌐)** → **paste** mode (icon turns **red**). The transcript is pasted
  verbatim — no voice-tool interpretation.
- **Ctrl+Fn** → **command** mode (icon turns **magenta**). The transcript is run
  to the app registered for commands (never pasted; see below). A distinct
  start/stop chirp signals command mode; a "sad" chirp means nobody took it.

Each mode supports **hold** (push-to-talk) and **double-tap** (transcribe lock; next
press stops). Pressing **⌘ while holding** Fn locks a push-to-talk you have already
started, so you can let go and keep talking. Recording carries on for half a
second after the key that ends it, so your last word is not clipped.

Tapping **left Shift while recording** cycles how the transcript lands mid-line:
lowercase first word, no trailing punctuation, both, or as dictated. **Recent
Dictations** in the menu keeps each transcript (and the raw one, before
clean-up) with **Retry** and **Copy**.

Set System Settings → Keyboard → "Press 🌐 key to" = **Do Nothing** so Fn doesn't
also trigger emoji/dictation/input-switching.

## Voice commands (command mode — Ctrl+Fn)

Voice Operator doesn't interpret commands itself. The verbatim transcription goes
to whichever local app registered for commands (Spaceterm today), which decides
what it means; with none registered, the error chirp plays. See `DESIGN.md`,
"Dictation and command mode".

## Global shortcuts

Fire from any app (they run off the CGEvent tap, so no window focus needed):

- **⌘⌃V** — re-paste the last text Voice Operator pasted, into the frontmost app.
- **⌘⌃S** — speak the clipboard aloud; press again to stop.
- **⌘⌃A** — replace the clipboard with a one- or two-sentence Haiku summary of it.
  Needs chriswa-devkit's `claude-print-daemon` on your shell's PATH and Claude Code signed in.
- **⌘⌃B** — mute or unmute narration (same as the menu-bar **Mute Speech** item).
- **⌘⌃/** — move the word overlay: bottom → lower middle → middle → upper
  middle → top → hidden → bottom. Saved between
  restarts; the menu's **Word Overlay** submenu shows the current one and picks any directly.
  With nothing being read, the empty bar flashes at its new spot for 200 ms.
- **⌘⌃,** / **⌘⌃.** — slow down / speed up active speech by **0.2×**, from **0.5× to 5.0×**.
  Speed is saved between reads and app restarts; the default is 1.0×.
- **⌘⌃←** — rewind **3 seconds**, including previous sentences of the same read.
  Works for **two seconds after speech finishes**, too. The visual reader follows the audio.
- **⌘⌃→** — skip ahead **3 seconds**, including into upcoming sentences of the same read.

Playback controls and the current speed also appear in the menu. Rewind after completion
keeps the same speed; a new read, dictation, mute or stopping playback clears that replay window.
Tiny solid black triangles centered within the reader's upper white border show the speed setting:
left for slower, right for faster, one triangle per 0.2× away from normal. At 1.0× none appear.

They stop working entirely — with no other symptom, while dictation carries on —
whenever an app holds macOS **secure event input** (Terminal's "Secure Keyboard
Entry", say), which withholds key events from every event tap. Voice Operator
detects this: the menu names the app holding it, and the log says
`secure input: ON (held by …)`.

## Transcription backends

Dictation goes through a **transcription provider**, chosen from the menu bar's
**Transcription** submenu (the choice survives restarts):

- **Wispr Flow** — described below. Used only when chosen in the menu; greyed
  out on a Mac without a Wispr sign-in.
- **Parakeet (on this Mac)** — the default, on every Mac. NVIDIA Parakeet TDT
  v2 (English) via FluidAudio, entirely on device. Raw recognition with its own punctuation and casing: no clean-up
  and no custom vocabulary. The model (a few hundred MB) downloads from Hugging
  Face the first time it is chosen and loads at every launch. If it fails, the
  dictation fails — it never falls back to Wispr.

The same submenu can turn on a **shadow** provider: it gets the same audio,
never pastes, and its transcript is filed beside the real one in **Recent
Dictations** (each entry's submenu shows it and can copy it). **Copy Last Shadow
Transcript** copies the most recent one.

`WisprFlowProvider` uses Wispr's gRPC path, which returns
**formatted** text honouring your Wispr dictionary. It needs Wispr's Baseten
API key, read at runtime from `$VOICEOP_BASETEN_KEY` or
`~/Library/Application Support/VoiceOperator/baseten-key`. **Never commit it.**

Without the key the app silently falls back to `WisprTranscriber` (raw
`/llm/asr`). That fallback is plain Whisper: still punctuated and capitalized,
but with **no dictionary biasing and no formatting pass**, so proper nouns and
jargon come back misspelled ("kubectl", "Coda" and friends).

Since both paths return plausible-looking text, check the log to see which one
actually ran:

```bash
grep "flow:" ~/Library/Logs/VoiceOperator.log | tail
```

`flow: gRPC ok — N chars` is the formatted path. `flow: no Baseten key` or
`flow: gRPC failed (…)` means you're on the raw fallback.

## Transcript clean-up

**Clean Up Transcripts (Fluid-1 Mini)** in the menu bar menu runs each transcript
through [Fluid-1 Mini](https://huggingface.co/altic-dev/fluid-1-mini), a small
model tuned for cleaning up dictation, on this Mac before it is pasted: it drops
fillers, applies "scratch that"-style corrections, formats numbers, and follows
spoken commands like "new paragraph". It adds about half a second. If it fails,
the raw transcript is pasted.

The model's licence allows **personal, non-commercial use only**, so Voice
Operator does not download it for you. Read the licence on its Hugging Face
page, then download it to where the app looks for it (1.6 GB):

```bash
mkdir -p ~/Library/Application\ Support/VoiceOperator/cleanup
curl -L --fail -o ~/Library/Application\ Support/VoiceOperator/cleanup/fluid-1-mini-q6_k.gguf \
  https://huggingface.co/altic-dev/fluid-1-mini/resolve/af4b6e10a3631c346f77ca8c1018b59743433aa5/fluid-1-mini-q6_k.gguf
```

Then tick the checkbox. The app checks the file against the expected SHA-256,
downloads [llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT) beside it,
and runs it as a background service while the checkbox is on. Turning the
checkbox off stops the service and frees its memory (about 2 GB). **Delete
Clean-Up Model** removes the whole folder. While the model is missing, a **Clean-Up Setup
Instructions…** item under the checkbox opens this section.

## Text to Speech

Speech goes through the Kokoro TTS server Voice Operator runs on this Mac, at
`http://127.0.0.1:56841`, managed from the menu's **Text to Speech** submenu.
Nothing to set up: on first launch Voice Operator installs it by itself, with a
progress window — it copies the server (from `kokoro/` in this repo, shipped inside
the app) to Application Support, builds its Python environment with
[`uv`](https://docs.astral.sh/uv/) (downloading uv and Python if the Mac has
neither; ~900 MB in all), and runs it as a launchd agent. The first start
downloads the voice model (~325 MB). The submenu shows its status and memory,
and has **Install**, **Update**, **Restart** and **Uninstall**. See
[`kokoro/CLAUDE.md`](kokoro/CLAUDE.md).

There is no way to send speech to another server: what is spoken never leaves the
Mac. (A custom-server option existed until 2026-10-13.)

## Audio settings

In the menu bar menu:

- **Mute System Audio While Dictating** — other audio is muted while you
  dictate, and unmuted after.
- **Keep Microphone Always On** (or **Only When Using AirPods (Bluetooth)**) —
  holds the microphone open between dictations, so a Bluetooth headset does not
  drop into its call profile, and back, at every dictation.
- **Tap to Toggle Dictation** — every Fn press starts or stops, instead of
  hold / double-tap.

## Hands-free

Hands-free is always-on listening for a **trigger word** that a client app
registers ("control", for Spaceterm). Nothing listens until a client connects
and asks, and nothing outlives that connection. While it is on:

- Say the trigger word first — "Control, what's Kevin doing?" — and keep
  talking; you are transcribed from your first syllable. Stop when you are done:
  a streaming end-of-turn model, [turn-1-mini](https://huggingface.co/p99lab/turn-1-mini)
  (p99lab, Apache-2.0), decides when you have finished — half a second after
  its score first reaches its threshold in a pause, unless you speak again
  first. A silence timeout (3 s, 4 s at most in a long dictation) is the
  fallback. [Smart Turn](https://github.com/pipecat-ai/smart-turn) is asked
  too, once per pause, for comparison only. The transcript goes to the client.
- After that, a **conversation window** lets you reply without the trigger word
  until both sides have been quiet for 15 seconds.
- Talking over the client's own voice turns it down, and cuts it off once it is
  clear you meant it, counted to when you began.
- "Let me turn this off" — or "<trigger>, shutdown" — turns hands-free off.

It listens on the Mac's microphone (your Fn dictation always takes priority, and
it does not listen while Voice Operator speaks on the Mac's speakers, so
barge-in on the Mac needs a headset) or on audio a client streams in — a phone,
through the iOS SDK. Detecting speech (Silero VAD), checking the trigger word
(Apple's on-device model, macOS 26) and both end-of-turn models all run on the
Mac (the two models, about 14 MB, download from Hugging Face on first use);
the transcription uses your chosen provider. While hands-free holds the Mac's
microphone, speech does not turn other audio down (doing so tore the
microphone down at every reply). A Voice Operator restart leaves a client's
hands-free on, and it starts again once the app is back. What it heard and
decided — every check, every pause with both models' scores, every dictation's
start and end — is kept for review in
`~/Library/Application Support/VoiceOperator/hands-free/` (DESIGN.md,
"Debugging it").

## Incognito mode

**Incognito Mode** in the menu turns the menu-bar megaphone into sunglasses and
keeps everything you say or hear on this Mac, and off its disk: no history, no
saved clips, no TTS cache, no words in the log, no Wispr Flow, no clipboard
summaries, nothing to or from Spaceterm. Dictation works through Parakeet and
speech through the local Kokoro. It stays on across restarts. See DESIGN.md,
"Incognito mode".

## For developers: the local API

At launch Voice Operator writes
`~/Library/Application Support/VoiceOperator/speech-service.json` with its
loopback port and the hands-free socket's path. There is no authentication: it
serves the current user only, on loopback. In brief (full tables in
`DESIGN.md`):

| What | Where |
| --- | --- |
| Speak text (one or several voices), poll or long-poll it, stop it — a stop reports how far the listener got | `POST /v1/speech`, `GET`/`DELETE /v1/speech/{id}` |
| Synthesize without playing: audio plus word timings, for playback elsewhere | `POST /v1/synthesize` |
| Transcribe audio captured elsewhere, streamed in | `/v1/transcriptions` |
| Receive command dictations (Ctrl+Fn) and dictation start/stop events on your own socket | `PUT /v1/subscribers/{name}` |
| What it is doing; ask it to restart when idle | `GET /v1/status`, `POST /v1/restart` |
| Hands-free: register a trigger word, turn it on, follow its state, receive transcripts | newline-JSON on the Unix socket — DESIGN.md, "Hands-free" |

### iOS SDK

`sdk/VoiceOperatorKit` is a Swift package (iOS 17, and macOS for its tests):

- `VoiceOperatorHandsFree` — the hands-free stream client. Transport-agnostic:
  the app carries its lines to the Mac (Spaceterm relays them through its
  server). It numbers the audio, keeps a minute of it until the Mac has it, and
  resumes a session after a dropout.
- `VoiceOperatorAudio` — the audio engine: the microphone with echo
  cancellation, speech playback through one player (the app's own sounds mix
  into it), and the audio-session rules that keep AirPods, the speaker,
  Spotify and a locked screen working.

```bash
cd sdk/VoiceOperatorKit && swift test
# one real transcription across a dropout, against the running app:
VOICEOP_SDK_SPEECH_TEST=1 swift test --filter testSpeechWithADropoutComesBackAsTheTranscript
```

## Building from source

**Runtime:** the latest macOS release on Apple Silicon (`arm64`). Intel Macs are
not supported. See [`docs/RELEASING.md`](docs/RELEASING.md).

**Building from source** still needs a full Xcode 16+ toolchain on an Apple Silicon
Mac (Swift 6 / `swift-tools-version: 6.0`). The Command Line Tools alone are **not**
sufficient: SwiftPM invokes `xcrun --show-sdk-platform-path`, which only resolves
inside a full Xcode installation.

```bash
swift --version           # want 6.0+
xcode-select -p           # want /Applications/Xcode.app/Contents/Developer
```

If `xcode-select -p` reports `/Library/Developer/CommandLineTools`:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Optional: `protoc` (`brew install protobuf`) — only needed to regenerate the
gRPC/protobuf Swift via `scripts/gen-proto.sh`. The generated sources are
checked in, so a normal build doesn't need it.

### Troubleshooting

- **`xcrun: error: unable to lookup item 'PlatformPath' … in SDK
  '/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk'`** — full Xcode isn't
  selected. See `xcode-select -s` above.
- **`package … is using Swift tools version 6.0.0 but the installed version is
  5.x`** — your toolchain predates Swift 6. Xcode 16+ is required.

## Build & run

```bash
swift build                 # compile (host arch)
swift test                  # unit tests
./scripts/make-app.sh       # build "build/Voice Operator.app" (menu-bar accessory)
open "build/Voice Operator.app"
```

For a notarized release binary, see [`docs/RELEASING.md`](docs/RELEASING.md)
(`./scripts/make-release.sh`).

### Iterating on changes

`./scripts/make-app.sh` builds the app and then asks the running one to restart
itself (`POST /v1/restart`). The app waits until nobody is dictating or
listening to speech, plays a cue, and relaunches; the script waits for the new
version to report in and prints `restarted: v0.1.NN`. If it exits non-zero, the
new build is **not** running — read its message. Never `kill` the app: a
restart mid-dictation loses what was being said. **Restart Voice Operator** in
the menu does the same, when you choose.

```bash
./scripts/make-app.sh       # rebuild, and restart cooperatively
```

History and settings persist across restarts, and permissions stick to the
stable signature.

For logs during dev, run the executable directly:

```bash
"build/Voice Operator.app/Contents/MacOS/VoiceOperator"
```

## Live self-tests

Each makes at most one transcription or synthesis; none needs the microphone.

```bash
B=.build/debug/VoiceOperator
$B --provider-test parakeet "some text"   # a provider's live path, with say-made speech
$B --cleanup-test "um so send it friday"  # Parakeet plus the on-device clean-up
$B --hands-free-test "what is Kevin doing" # hands-free end to end, against the running app
$B --flow-grpc-test "kubectl and Coda"    # Wispr Flow's formatted gRPC path
$B --asr-test "your test phrase"          # Wispr's raw /llm/asr fallback
$B --transcribe-file clip.wav             # a stored clip through Wispr
$B --tts-test                             # speech through the local Kokoro
```

## spike/

`spike/asr_spike.py` — the original Phase 0 proof (Python). One request per run.
