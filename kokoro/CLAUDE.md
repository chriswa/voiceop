# CLAUDE.md — Kokoro TTS server

Voice Operator's local speech server: `kokoro_server.py`, FastAPI + Kokoro-82M
(Apache 2.0, 82M params) on Apple Silicon (`mps`). Kokoro was picked over
Chatterbox, Fish, Orpheus and Parler for being fast, small, good enough and
trivially deployable; those trial servers are gone (see git history before the
merge into this repo). The Swift side that talks to it is
`Sources/VoiceOperator/Speaker/KokoroSynthesizer.swift`.

---

## Installed and managed by Voice Operator

Users never set this up by hand. The **Text to Speech** submenu (Install / Update /
Restart / Uninstall / Show Kokoro Log) drives `KokoroService`:

- **Source of truth is this folder.** `make-app.sh` / `make-release.sh` copy
  `kokoro_server.py`, `requirements.txt` and `blocked_voices.json` into
  `Voice Operator.app/Contents/Resources/kokoro/`. Install copies them from there.
  An edit here reaches the installed server only via a rebuilt app + **Update Kokoro**.
- **Installed at** `~/Library/Application Support/VoiceOperator/kokoro/`: the
  server, `requirements.txt`, `blocked_voices.json` (seeded once, never
  overwritten — it is runtime state), and `venv/` (Python 3.13, built by `uv`
  from `requirements.txt`, ~900 MB).
- **One launchd agent**, `com.chriswa.voiceoperator.kokoro`
  (`~/Library/LaunchAgents/com.chriswa.voiceoperator.kokoro.plist`, written by the
  app): `RunAtLoad` + `KeepAlive`, `ThrottleInterval 10`. There is **no** scheduled
  restart any more (see "Memory" below).
- **Log:** `~/Library/Logs/VoiceOperator-kokoro.log` (server output plus the
  install's `uv` output). Truncated at install/update/restart once past 5 MB.
- **Never `kill` it** — `KeepAlive` respawns it anyway, and it cuts off whatever the
  user is listening to. Use the menu's **Restart Kokoro**, which waits until
  nothing is being dictated or spoken. The same rule as Voice Operator itself (root
  `CLAUDE.md`, "Never kill the process…").

Inspect without changing anything:
```bash
launchctl print gui/$(id -u)/com.chriswa.voiceoperator.kokoro | grep -E 'state|pid'
curl -s localhost:56841/health   # → {"status":"ok",...,"pid":…,"memory_mb":1843,"mps_mb":1264,"vram_mb":0}
tail -f ~/Library/Logs/VoiceOperator-kokoro.log
```

**Migrating an old hand-made setup.** Before the merge this ran from a `~/tts`
checkout under `com.chriswa.kokoro-tts` (+ a `com.chriswa.kokoro-tts-restart` 02:00
agent). Install retires those: after the new venv is built it boots them out and
moves their plists to `~/Library/Application Support/VoiceOperator/legacy-kokoro-launchagents/`
(never deleting them, never touching `~/tts`); if the new server fails to come up
it puts them back.

---

## Working on the server directly

```bash
cd kokoro
uv venv --python 3.13 venv          # 3.13, NOT 3.14 (no torch wheels)
VIRTUAL_ENV=venv uv pip install -r requirements.txt
PORT=56899 ./venv/bin/python kokoro_server.py   # a spare port: 56841 is the installed agent's
```
Run your copy on a **spare port** rather than stopping the installed agent — the
user may be listening to it. If you truly need 56841, ask the user first; don't
`launchctl bootout` it out from under the app.

`requirements.txt` is the exact package set known to work (torch 2.14.0,
kokoro 0.9.4, misaki 0.9.4, spacy 3.8.x + the `en_core_web_sm` 3.8.0 wheel, …).
Change it deliberately: Update re-runs `uv pip install` when it changes.

---

## Configuration

`kokoro_server.py` loads an optional `.env` from its own directory (tiny built-in
loader, real environment variables win, loaded *before* `import torch`). The code
defaults are what Voice Operator expects, so normally there is no `.env`:

| Var | Default | Notes |
|-----|---------|-------|
| `PORT` | `56841` | Voice Operator's `Config.defaultTTSBaseURL`. |
| `HOST` | `127.0.0.1` | Loopback only. `0.0.0.0` exposes it to the LAN with **no auth**. |
| `KOKORO_DEVICE` | auto (`cuda`→`mps`→`cpu`) | Force e.g. `cpu` if MPS hits an unsupported op. |
| `PYTORCH_ENABLE_MPS_FALLBACK` | `1` (set in code) | Unsupported MPS ops fall back to CPU instead of erroring. |

---

## Memory

On MPS, PyTorch caches a compiled MPSGraph per distinct tensor shape and never
evicts it (pytorch/pytorch #181213, #164299). The vocoder's shapes follow the audio
length, so a long-lived server grew ~40 MB per new utterance length — **~19 GB
after 4 days**. Fixed in code since torch 2.14: `_advance()` calls
`torch.mps.synchronize(); torch.mps.empty_cache()` after every model step, which
reclaims it (120 varied requests stay flat at ~1.8 GB, no latency cost). On torch
2.13 `empty_cache()` did *not* reclaim it — **don't go below 2.14**. CPU has no leak
but is ~3.7× slower (RTF 0.15 vs 0.042), so we stay on MPS.

The old daily 02:00 restart was a safety net for this and has been **removed**.
Instead the server reports its memory, so a returning leak (e.g. after a torch
upgrade) is visible:

- **Physical footprint** (Activity Monitor's "Memory") via libproc
  `proc_pid_rusage` → `ri_phys_footprint` (`_footprint_mb()`), and the Metal
  driver's share via `torch.mps.driver_allocated_memory()` (`_mps_mb()`, sampled
  inside `_advance()` under the inference lock — MPS must never be entered from two
  threads).
- Logged on the `Kokoro ready …` line and every `[tts N] finish` / `[ts N] finish`
  line as `mem=…MB mps=…MB`.
- Served by `/health` as `memory_mb` / `mps_mb` (+ `pid`). Voice Operator probes
  `/health` each time its menu opens and shows `Memory: 1.8 GB` under the status line.

---

## Portability

- **Never call `torch.cuda.*` unguarded** — use `_vram_mb()` (0 off CUDA) and
  `_pick_device()` (`KOKORO_DEVICE` → `cuda` → `mps` → `cpu`). A bare
  `torch.cuda.memory_allocated()` at startup kills a non-NVIDIA box.

---

## API

Native, not OpenAI-compatible — there is **no** `/v1/audio/speech`. Loopback only,
no CORS.
- `GET /` — HTML test page (voice picker, synth, block-a-voice).
- `GET /health` — `{status, model, loaded, pid, memory_mb, mps_mb, vram_mb}`.
- `GET /voices` — active voices (block-listed ones filtered out) + `default`.
- `POST /synthesize` — body `{ "text": str, "voice"?: str, "speed"?: float }`.
  Streams 16-bit mono WAV @ 24000 Hz: a 44-byte header with placeholder sizes, then
  PCM chunks as generated (unpaced — the client buffers).
- `POST /timestamps` — same body. JSON `{ words: [{ word, start, end }], duration,
  sample_rate, ... }`, word timings (seconds from utterance start) from Kokoro's own
  duration predictor, via a vocoder-free duration-only model (`_DurationOnlyModel`,
  falls back to a full synth if Kokoro internals change). Deterministic for a given
  (text, voice, speed), so it lines up with `/synthesize`.
- `POST /voices/block` — add a voice to `blocked_voices.json` (one-way; edit the
  file to undo).

Defaults/limits: `DEFAULT_VOICE=af_heart`, `DEFAULT_SPEED=1.2`, speed 0.5–2.0,
`MAX_TEXT_LEN=5000`, model `hexgrad/Kokoro-82M`. Languages: English (US/UK),
Spanish, French, Hindi, Italian, Portuguese — Japanese/Mandarin need extra packages.

Smoke test (against your spare-port copy):
```bash
curl -s localhost:56899/health
curl -s -X POST localhost:56899/synthesize -H 'Content-Type: application/json' \
  -d '{"text":"Hello from Kokoro."}' -o out.wav && file out.wav   # → RIFF WAVE 24000 Hz
```

---

## Gotchas

- **espeak-ng path limit.** misaki's fallback G2P loads espeak-ng from the
  `espeakng_loader` wheel (no Homebrew `espeak-ng` needed). If the venv's
  `…/site-packages/espeakng_loader/espeak-ng-data` path is **160+ characters**,
  espeak-ng silently falls back to a compiled-in path, prints `Error processing
  file '/Users/runner/work/espeakng-loader/…/phontab'`, and the process exits at
  model load. Keep venvs at shallow paths; Install refuses one that is too deep.
- **uv venvs have no pip** → runtime `pip`/spacy-download subprocesses fail. That
  is why `requirements.txt` carries the `en_core_web_sm` wheel URL.
- **Python 3.14 has no torch wheels** — the venv is 3.13.
- First start downloads the model from Hugging Face (~325 MB, cached in
  `~/.cache/huggingface`; `HF_TOKEN` raises rate limits; `HF_HUB_OFFLINE=1` skips the
  update check once cached).
