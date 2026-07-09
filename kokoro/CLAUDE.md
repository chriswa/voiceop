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
- **Run it:** `./venv_kokoro/bin/python kokoro_server.py` (reads `.env`
  automatically). Nothing is set up to survive reboot — it's launched manually.

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

Known-good versions on this Mac: torch 2.13.0, kokoro 0.9.4, misaki 0.9.4,
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

This Mac's `.env`:
```
PORT=56841
KOKORO_DEVICE=mps
PYTORCH_ENABLE_MPS_FALLBACK=1
```

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
- The Mac process is foreground/manual; there's no launchd unit yet.
