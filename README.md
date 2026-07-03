# Voice Operator

Native macOS menu-bar app that unifies **dictation** (replacing Wispr Flow) and
spoken **Claude Code updates** (replacing `transcript-reader.py`) under one audio
coordinator, so dictation always mutes/halts TTS and no spoken update is missed.

See `DESIGN.md` for architecture, reverse-engineering findings, and the phased plan.

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

- **Hold Fn (🌐)** → dictate while held (push-to-talk).
- **Double-tap Fn** → hands-free; the next Fn press stops.

Set System Settings → Keyboard → "Press 🌐 key to" = **Do Nothing** so Fn doesn't
also trigger emoji/dictation/input-switching.

## Voice commands

Dictate one of these (instead of it being pasted). A verb with **no name**
targets the **last-referenced** agent — the last one that spoke *or* that any
tool (repeat / more details / surface) last acted on:

- **"Focus ⟨name⟩"** — raise that Claude surface in spaceterm. Name homophones
  resolve (e.g. "Focus Amber" → Ember).
- **"More details ⟨name⟩"** — re-summarize that surface's latest update with
  *new* depth (doesn't repeat what was already said). Iterable; when there's
  nothing left it says "No more information to summarize."
- **"Repeat ⟨name⟩"** — replay that surface's latest update (free, from cache).

The menu-bar **Recent Updates → ⟨entry⟩** submenu offers **Replay**, **Focus**,
and **More details** for the same actions by click.

## Re-paste

**⌘⌃V** re-pastes the last text Voice Operator pasted, into the frontmost app.

## STT self-test (mic-free, one request)

```bash
swift run VoiceOperator --asr-test "your test phrase"
```

Synthesizes speech with `say`, transcodes to the ASR WAV format, and makes a
single `POST /llm/asr` call. Uses the Wispr token read from its `session.json`.

## spike/

`spike/asr_spike.py` — the original Phase 0 proof (Python). One request per run.
