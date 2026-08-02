# Voice Operator

Native macOS menu-bar app that unifies **dictation** (replacing Wispr Flow) and
spoken **Claude Code updates** (replacing `transcript-reader.py`) under one audio
coordinator, so dictation always mutes/halts TTS and no spoken update is missed.

See `DESIGN.md` for architecture, reverse-engineering findings, and the phased plan.

## Requirements

All three are hard requirements — the build fails without them.

| Requirement | Why |
|---|---|
| **macOS 15 (Sequoia) or newer** | `Package.swift` sets a `.macOS(.v15)` deployment target. The floor comes from grpc-swift 2.x, whose generated client is `@available(macOS 15.0, *)` — not from the app's own code, which uses only AppKit/Carbon/AVFoundation APIs available much earlier. |
| **Apple Silicon (arm64)** | `Sources/COpus/lib/libopus.a` is a prebuilt **arm64-only** static archive. Intel Macs fail at the link step; see `Sources/COpus/README.md` to rebuild it for x86_64. |
| **Full Xcode 16 or newer** | `swift-tools-version: 6.0` requires Swift 6.0+. The Command Line Tools alone are **not** sufficient: SwiftPM invokes `xcrun --show-sdk-platform-path`, which only resolves inside a full Xcode installation. |

Verify before building:

```bash
sw_vers -productVersion   # want 15.0+
uname -m                  # want arm64
swift --version           # want 6.0+
xcode-select -p           # want /Applications/Xcode.app/Contents/Developer
```

If `xcode-select -p` reports `/Library/Developer/CommandLineTools`, install Xcode
and point the toolchain at it:

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
  5.x`** — your toolchain predates Swift 6. Xcode 16+ is required, which in turn
  requires macOS 14.5+.
- **A link error naming `libopus.a` and a mismatched architecture** — the
  vendored archive is arm64; rebuild it for your CPU per `Sources/COpus/README.md`.

## Transcription backends

`WisprFlowTranscriber` (the default) uses Wispr's gRPC path, which returns
**formatted** text honouring your Wispr dictionary. It needs Wispr's Baseten
API key, read at runtime from `$VOICEOP_BASETEN_KEY` or
`~/Library/Application Support/VoiceOperator/baseten-key`. **Never commit it.**

Without the key the app silently falls back to `WisprTranscriber` (raw
`/llm/asr`). That fallback is plain Whisper: still punctuated and capitalized,
but with **no dictionary biasing and no formatting pass**, so proper nouns and
jargon come back misspelled ("kubectl", "Coda" and friends). If dictation is
mangling your custom vocabulary, check the key first.

## Build & run

```bash
swift build                 # compile
swift test                  # unit tests
./scripts/make-app.sh       # build "build/Voice Operator.app" (menu-bar accessory)
open "build/Voice Operator.app"
```

### Iterating on changes

Rebuild, then use the menu-bar **Restart Voice Operator** item to pick up the new
build — you control the timing, so nothing gets killed mid-dictation. State
(history, name↔session registry) persists across the restart and TCC permissions
stick to the stable signature, so it's seamless.

```bash
./scripts/make-app.sh       # rebuild the .app; then click "Restart Voice Operator"
```

**Restart** spawns a tiny detached helper that waits for the current process to
exit, then relaunches the app and exits itself.

For logs during dev, run the executable directly:

```bash
"build/Voice Operator.app/Contents/MacOS/VoiceOperator"
```

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
  through the voice-tool router *only* (never pasted). A distinct start/stop
  chirp signals command mode; a "sad" chirp means no tool matched (transcript
  dropped).

Each mode supports **hold** (push-to-talk) and **double-tap** (hands-free; next
press stops).

Set System Settings → Keyboard → "Press 🌐 key to" = **Do Nothing** so Fn doesn't
also trigger emoji/dictation/input-switching.

## Voice commands (command mode — Ctrl+Fn)

In command mode, **say the agent's name first**, then either a reserved word or
your message. The leading word counts as a name only if it's a currently-active
call-sign (homophones resolve, e.g. "Amber" → Ember); otherwise there's no name
and your words target the **last-referenced** agent — the last one that spoke or
that a command last acted on.

- **"⟨name⟩"** — raise that Claude surface in spaceterm. (A lone **"focus"** does
  the same for the last agent.)
- **"⟨name⟩ repeat"** — replay that surface's latest update (free, from cache).
- **"⟨name⟩ ⟨message⟩"** — anything that isn't `repeat`/`focus`/`skip` is an
  *aside*: a spoken question about that update, in a continuing conversation (it
  may repeat or go deeper — e.g. "⟨name⟩, give me more detail"). Read-only: it
  talks only to the low-context Haiku summarizer, not the real Claude session.
  With no name, the question goes to the last agent.
- **"skip"** — global; drop the clip playing now so playback advances.

The menu-bar **Recent Updates → ⟨entry⟩** submenu offers **Replay** and
**Focus** for the same actions by click.

## Global shortcuts

Fire from any app (they run off the CGEvent tap, so no window focus needed):

- **⌘⌃J** — focus the surface of the last agent that spoke (same as the menu-bar
  **Focus ⟨name⟩** item; tracks whoever is speaking the moment narration starts).
- **⌘⌃V** — re-paste the last text Voice Operator pasted, into the frontmost app.

## STT self-test (mic-free, one request)

```bash
swift run VoiceOperator --asr-test "your test phrase"
```

Synthesizes speech with `say`, transcodes to the ASR WAV format, and makes a
single `POST /llm/asr` call. Uses the Wispr token read from its `session.json`.

## spike/

`spike/asr_spike.py` — the original Phase 0 proof (Python). One request per run.
