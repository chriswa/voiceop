# CLAUDE.md — Local TTS service

Self-hosted TTS to replace Cartesia. See `PLAN.md` for the model-selection story
and benchmarks. **Kokoro-82M is the chosen production engine** (`kokoro_server.py`);
the other `*_server.py` files (chatterbox, fish, orpheus, parler) are evaluation
leftovers, not the live service.

This project runs on **two very different machines**. Read the machine section for
the box you're on before changing anything, and keep changes portable across both.

---

## The two machines

### 1. Primary / production — Linux box "WillowPC" (RTX 4060, WSL2)
- **Path:** `/home/willo/acp-host-projects/tts`
- **GPU:** NVIDIA RTX 4060, 8 GB VRAM. Device = `cuda`. CUDA toolkit 12.8.
- **Python:** system `python3` (3.12.x). Kokoro/Chatterbox/Parler run against
  system/user-site packages — **no venv** for those (see `start_kokoro.sh`:
  `exec python3 -W ignore kokoro_server.py`).
- **Per-engine venvs exist only where torch versions conflict:** `venv_fish/`
  and `venv_orpheus/` have their own interpreters. Fish needs torch 2.8 which
  conflicts with Chatterbox, so it's isolated. Don't try to unify these.
- **Port:** **3004**, hard-coded expectation. This is the code default and what
  the Cloudflare tunnel + other services point at. **Do not change the 3004
  default** — it's baked into the primary install's routing (`tts.chriswa.com`
  via Cloudflare Access). Start scripts export CUDA paths then exec the server:
  ```
  export PATH=/home/willo/.local/bin:/usr/local/cuda-12.8/bin:$PATH
  export LD_LIBRARY_PATH=/usr/local/cuda-12.8/lib64:$LD_LIBRARY_PATH
  ```
- **Boot persistence:** watched via `~/nssm-wsl-startup.sh` (per PLAN.md). The
  `start_*.sh` scripts are the entry points there.

### 2. Dev box — this Mac (Apple Silicon, arm64)
- **Path:** `/Users/chriswaddell/tts`
- **GPU:** Apple Silicon. Device = `mps` (falls back to `cpu`). No CUDA — any
  `torch.cuda.*` call will crash, so those are guarded (see below).
- **Python:** **3.13** in `venv_kokoro/` (created with `uv`). NOT 3.14 — the
  system `python3` is 3.14 and **torch has no 3.14 wheels yet**. Use 3.13.
- **Port:** **56841** — a fixed high port chosen because the 3000 range is
  crowded with other local services here. Standardize other local services on
  56841. Set via `.env` (see below), NOT by editing the code default.
- **Run it:** managed by **launchd** — starts at login, survives reboot, and
  auto-restarts on crash (see "Boot persistence & daily restart (Mac)" below).
  For ad-hoc debugging you can still run it in the foreground with
  `./venv_kokoro/bin/python kokoro_server.py` (reads `.env` automatically) — but
  `launchctl bootout gui/501/com.chriswa.kokoro-tts` first so the two don't fight
  over the port.

---

## Fresh-box setup (Kokoro)

### On a Mac / non-CUDA box
```bash
brew install espeak-ng                      # misaki (English G2P) fallback
uv venv --python 3.13 venv_kokoro           # 3.13, NOT 3.14 (no torch wheels)
VIRTUAL_ENV=venv_kokoro uv pip install torch kokoro fastapi uvicorn numpy soundfile
# REQUIRED: pre-install the spacy model. misaki auto-downloads en_core_web_sm at
# runtime via a subprocess, and uv-created venvs have no pip, so that download
# fails with "No virtual environment found; run `uv venv`". Pre-installing avoids it:
VIRTUAL_ENV=venv_kokoro uv pip install \
  "https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"
```
Then create a machine-local `.env` (see next section) and run
`./venv_kokoro/bin/python kokoro_server.py`.

Known-good versions on this Mac: torch 2.14.1, kokoro 0.9.4, misaki 0.9.4,
transformers 5.13.0, spacy 3.8.14, en_core_web_sm 3.8.0, numpy 2.5.1,
fastapi 0.139.0, uvicorn 0.51.0, soundfile 0.14.0.

### On the Linux CUDA box
Follow `PLAN.md` Phase 1 (CUDA toolkit + `torch ... --index-url .../cu124`).
Kokoro/Chatterbox/Parler install into system/user site; Fish/Orpheus get their
own venvs. Device auto-selects `cuda`. Leave the port at the 3004 default.

---

## Configuration (`.env`)

`kokoro_server.py` loads a `.env` from its own directory at import (tiny built-in
loader, no dependency). **Real environment variables win over `.env`**, and the
`.env` load happens *before* `import torch` so torch-read vars like
`PYTORCH_ENABLE_MPS_FALLBACK` take effect.

`.env` is **gitignored** (so is `venv_kokoro/`) — it's per-machine and must not
land in the primary install, which relies on the 3004 default.

Recognized vars:
| Var | Default | Notes |
|-----|---------|-------|
| `PORT` | `3004` | This Mac uses `56841`. Never change the code default. |
| `KOKORO_DEVICE` | auto (`cuda`→`mps`→`cpu`) | Force e.g. `cpu` if MPS hits an unsupported op. |
| `PYTORCH_ENABLE_MPS_FALLBACK` | unset | Set `1` on Mac so unsupported MPS ops fall back to CPU instead of erroring. |
| `KOKORO_EGRESS_PACING` | `on` | `/synthesize` meters audio out at ~1.3× realtime to smooth a lossy WAN hop (phone → Cloudflare Tunnel → production box). Set `off` on a box whose only client is local — it otherwise throttles delivery of audio that's already generated far faster than realtime. Not auto-detected by client IP: cloudflared runs on the production box, so real WAN requests arrive from 127.0.0.1 there too. |

This Mac's `.env`:
```
PORT=56841
KOKORO_DEVICE=mps
PYTORCH_ENABLE_MPS_FALLBACK=1
KOKORO_EGRESS_PACING=off
```

---

## Boot persistence & daily restart (Mac)

The Mac instance runs under **launchd**, not a terminal. Two user LaunchAgents in
`~/Library/LaunchAgents/` (UID here is **501** — check yours with `id -u` and
adjust the `gui/<uid>` targets and the plist's `gui/501/...` line if different):

- **`com.chriswa.kokoro-tts.plist`** — the server. `RunAtLoad` (starts at login /
  after reboot) + `KeepAlive` (respawns within ~5 s on crash or kill). launchd
  owns the process (PPID 1). Logs → `~/tts/kokoro.log`. `PORT` / `KOKORO_DEVICE`
  still come from `.env`, so the plist stays device-agnostic.
- **`com.chriswa.kokoro-tts-restart.plist`** — a `StartCalendarInterval` trigger
  at **02:00** daily that runs `launchctl kickstart -k` on the server. If the Mac
  is asleep (lid closed) at 2am, launchd coalesces the missed interval and fires
  it on the **next wake**. Logs → `~/tts/kokoro-restart.log`.

**Why the daily restart:** on MPS, PyTorch leaks memory via a shape-keyed
MPSGraph cache with no eviction (pytorch/pytorch #181213, #164299). A long-lived
server synthesizing variable-length text grows unbounded — observed **~19 GB
after 4 days**, ~40 MB per new utterance length (the vocoder's shapes follow the
audio length). **Fixed in code since torch 2.14:** `_advance()` calls
`torch.mps.synchronize(); torch.mps.empty_cache()` after every model step, which
now does reclaim it — 120 varied requests stay flat at ~1.8 GB with no latency
cost. (On torch 2.13 `empty_cache()` did *not* reclaim it; don't downgrade.)
The daily restart predates the fix and is now only a safety net. CPU has no such
leak but is ~3.7× slower (RTF 0.15 vs 0.042 measured here), so we stay on MPS.

**Set it up (fresh Mac, or after wiping `~/Library/LaunchAgents`):**
```bash
pkill -f kokoro_server.py                      # stop any manual instance (frees the port)
# ...create the two plists in ~/Library/LaunchAgents/ (full bodies below)...
plutil -lint ~/Library/LaunchAgents/com.chriswa.kokoro-tts*.plist   # sanity-check XML
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.chriswa.kokoro-tts.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.chriswa.kokoro-tts-restart.plist
# verify:
launchctl print gui/$(id -u)/com.chriswa.kokoro-tts | grep -E 'state|pid'
curl -s localhost:$(grep -E '^PORT=' .env | cut -d= -f2)/health
```

**Manage it:**
- Restart now: `launchctl kickstart -k gui/501/com.chriswa.kokoro-tts`
- Stop for good (use `bootout`, not `kill` — `KeepAlive` would just respawn a kill):
  `launchctl bootout gui/501/com.chriswa.kokoro-tts`
- Reload after editing a plist: `bootout` it, then `bootstrap` it again.
- Verify reboot survival *without* rebooting — unload then reload the agent and
  confirm it comes back (health should return within a few seconds):
  ```bash
  launchctl bootout gui/501/com.chriswa.kokoro-tts && \
    launchctl bootstrap gui/501 ~/Library/LaunchAgents/com.chriswa.kokoro-tts.plist && \
    sleep 3 && curl -s localhost:56841/health
  ```
- Tail logs: `tail -f ~/tts/kokoro.log`

The plists are **not** in the repo (Mac-only, absolute paths — like `.env`). Full
bodies for reproduction:

<details><summary><code>com.chriswa.kokoro-tts.plist</code></summary>

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.chriswa.kokoro-tts</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/chriswaddell/tts/venv_kokoro/bin/python</string>
        <string>-W</string>
        <string>ignore</string>
        <string>/Users/chriswaddell/tts/kokoro_server.py</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/Users/chriswaddell/tts</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>LANG</key>
        <string>en_CA.UTF-8</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>/Users/chriswaddell/tts/kokoro.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/chriswaddell/tts/kokoro.log</string>
</dict>
</plist>
```
</details>

<details><summary><code>com.chriswa.kokoro-tts-restart.plist</code></summary>

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.chriswa.kokoro-tts-restart</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>echo "[$(date)] daily restart -&gt; kickstart com.chriswa.kokoro-tts"; exec /bin/launchctl kickstart -k gui/501/com.chriswa.kokoro-tts</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>2</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/Users/chriswaddell/tts/kokoro-restart.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/chriswaddell/tts/kokoro-restart.log</string>
</dict>
</plist>
```
</details>

---

## Portability rules (learned the hard way)

The server was CUDA-only and crashed on the Mac. Keep it working on **both**:
- **Never call `torch.cuda.*` unguarded.** Use the `_vram_mb()` helper (returns 0
  off CUDA) and `_pick_device()` for device choice. A bare
  `torch.cuda.memory_allocated()` runs at startup and will kill a non-NVIDIA box.
- Device selection lives in `_pick_device()`: `KOKORO_DEVICE` override →
  `cuda` → `mps` → `cpu`. Don't reintroduce inline `"cuda" if ... else "cpu"`.
- Keep the `PORT` default at `3004`; make per-machine changes via `.env` only.

---

## API (what the server actually serves)

Despite PLAN.md's OpenAI-compatible aspiration, the live API is native — there is
**no** `/v1/audio/speech`. Endpoints:
- `GET /` — HTML test UI
- `GET /health` — `{status, model, loaded, vram_mb}` (vram_mb is 0 off CUDA)
- `GET /voices` — active voices (block-listed ones filtered out)
- `POST /synthesize` — body `{ "text": str, "voice"?: str, "speed"?: float }`.
  Returns streaming 16-bit mono WAV @ 24000 Hz.
- `POST /timestamps` (+ `OPTIONS`) — same body as `/synthesize`. Returns JSON
  `{ words: [{ word, start, end }], duration, sample_rate, ... }` with word-level
  timings (seconds from utterance start) for read-along / word-highlight overlays.
  From Kokoro's own duration predictor (`KPipeline` token `start_ts`/`end_ts`),
  deterministic for a given (text, voice, speed) so it lines up with `/synthesize`.
- `POST /voices/block` (+ `OPTIONS`) — manage `blocked_voices.json`.

Defaults/limits: `DEFAULT_VOICE=af_heart`, `DEFAULT_SPEED=1.2`,
speed 0.5–2.0, `MAX_TEXT_LEN=5000`, model `hexgrad/Kokoro-82M`.
`blocked_voices.json` is a runtime block-list (santa/duplicate-quality voices).

Smoke test:
```bash
curl -s localhost:$PORT/health
curl -s -X POST localhost:$PORT/synthesize -H 'Content-Type: application/json' \
  -d '{"text":"Hello from Kokoro."}' -o out.wav && file out.wav   # → RIFF WAVE 24000 Hz
```

---

## Gotchas
- **uv venvs have no pip** → runtime `pip`/spacy-download subprocesses fail.
  Pre-install everything (esp. `en_core_web_sm`). This is why setup lists it.
- **Python 3.14 has no torch wheels** — use 3.13 for the venv.
- Startup downloads the Kokoro model from HF (unauthenticated rate limits; set
  `HF_TOKEN` for faster/higher-limit pulls). First run is slower.
- The Mac process runs under launchd (see "Boot persistence & daily restart
  (Mac)"), not foreground. Stop the agent (`launchctl bootout`) before running
  manually, or the two fight over the port.
