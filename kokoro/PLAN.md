# Local TTS Service — Project Plan

Goal: Replace Cartesia with a self-hosted TTS service running on WillowPC's RTX 4060,
accessible from phone/remote via CloudFlare tunnel at `tts.chriswa.com`.

---

## Hardware Budget

| Resource | Available | Notes |
|----------|-----------|-------|
| VRAM | 8 GB | RTX 4060; currently ~1.2 GB in use (Xwayland) → ~6.8 GB free |
| RAM | ~13 GB | WSL2 allocation |
| CUDA | 13.2 | Driver ready; toolkit not yet installed |
| Python | 3.12.3 | No PyTorch yet |

---

## Candidates (Ranked by Fit)

### 🥇 Tier 1 — Test First

#### 1. Kokoro-82M
- **Params:** 82M | **License:** Apache 2.0 ✅ (commercial OK)
- **VRAM:** ~1.5 GB → leaves 5+ GB free, could co-host with small LLM later
- **Voices:** 54 built-in across 8 languages, no cloning
- **Latency:** ~50–100ms first-audio on RTX-class GPU; fastest available
- **Streaming:** Yes — Kokoro-FastAPI has OpenAI-compatible streaming endpoint
- **Verdict:** Best baseline. Fast, proven, trivial to deploy, OpenAI-compatible.
- **Deploy:** `ghcr.io/remsky/kokoro-fastapi-gpu` Docker image, or direct Python

#### 2. Chatterbox (Resemble AI)
- **Params:** 0.5B | **License:** MIT ✅ (commercial OK)
- **VRAM:** ~5–6 GB (tight but should fit; supports BF16 → ~4 GB)
- **Voices:** Voice cloning from 5-sec reference clip, emotion dial (0.0–1.0)
- **Latency:** Sub-300ms claimed; autoregressive so higher than Kokoro
- **Streaming:** Yes — `devnen/Chatterbox-TTS-Server` has OpenAI-compatible API
- **Verdict:** Best quality option that fits in 8 GB. Beats ElevenLabs in blind tests.
- **Deploy:** pip install + server, or Docker (`devnen/Chatterbox-TTS-Server`)

### 🥈 Tier 2 — Test if Tier 1 quality isn't good enough

#### 3. Orpheus TTS 3B (quantized)
- **Params:** 3B | **License:** Apache 2.0 ✅
- **VRAM:** 6.4 GB at bf16 (OOM on 4060!), **3.2 GB at INT8** ← use this
- **Voices:** 8 named voices, emotion tags in text, extremely natural output
- **Latency:** ~200ms first-audio with streaming; slower due to LLM-style generation
- **Streaming:** Yes, with SNAC decoder streaming
- **Verdict:** Most "human" sounding but needs quantization. Worth testing.
- **Deploy:** Quantized GGUF via llama.cpp or vllm

#### 4. Fish Speech S2
- **Params:** ~500M | **License:** CC-BY-NC-SA 4.0 ⚠️ (non-commercial only)
- **VRAM:** 4–6 GB at FP16
- **Voices:** Voice cloning from short reference, 80+ languages
- **Latency:** ~100ms TTFA on server hardware; slower on RTX 4060
- **Verdict:** Great quality, but non-commercial license. Fine for personal use.
- **Deploy:** `fish-speech` Python package with built-in API server

### ❌ Skip for now
- **Piper** — CPU-only, too robotic for Cartesia replacement
- **Bark** — Too slow, not streaming-friendly
- **XTTS v2** — Non-commercial license, superseded by better options
- **F5-TTS** — Non-commercial license (CC-BY-NC)

---

## Service Architecture (Target)

```
Phone/Remote app
      ↓ HTTPS
tts.chriswa.com  (CloudFlare tunnel)
      ↓
FastAPI TTS Server (port 3004)  ← always-loaded model in VRAM
      ↓
GPU inference → audio stream back
```

- **Port:** 3004 (free, following existing pattern)
- **API:** OpenAI-compatible (`POST /v1/audio/speech`) so any app works out of box
- **Streaming:** Chunked audio for low first-word latency
- **Auth:** CloudFlare Access (same as SSH — email whitelist)
- **Boot persistence:** Add to `~/nssm-wsl-startup.sh` watch loop

---

## Phase 1: Prerequisites

```bash
# Install CUDA toolkit in WSL (driver is already on Windows)
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt update
sudo apt install -y cuda-toolkit-12-4  # or latest matching driver

# Install PyTorch with CUDA
pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124

# Verify
python3 -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"
```

---

## Phase 2: Test Script Template

Each candidate gets tested with the same 3 sentences:
1. Short (~5 words) — measures TTFA
2. Medium (~25 words) — measures streaming flow
3. Long (~100 words) — measures sustained throughput

Metrics to capture per test:
- **TTFA** (time-to-first-audio, ms)
- **RTF** (real-time factor — generation time / audio duration)
- **VRAM used** (MB, idle + loaded + during generation)
- **RAM used** (MB)
- **Subjective quality** (user rates 1–5)

---

## Phase 3: Evaluation Matrix

All benchmarks on RTX 4060, torch 2.6.0+cu124. TTFA = time to first audio byte.

| Model | TTFA (short) | TTFA (long) | RTF (short) | RTF (long) | VRAM | License | Voice Cloning |
|-------|-------------|------------|------------|-----------|------|---------|---------------|
| **Kokoro-82M** | ~360ms | ~290ms | **0.23x** | **0.02x** | 550 MB | ✅ Apache 2.0 | ❌ 54 fixed voices |
| **Chatterbox** | ~4600ms | ~9500ms | 1.8x | 0.76x | 3060 MB | ✅ MIT | ✅ 5-sec clip |
| **Parler-TTS Mini** | ~12000ms | ~24000ms | 4.5x | 1.5x | 1700 MB | ✅ MIT | ❌ prompt-style |

Total VRAM with all three loaded: **7397 MB / 8188 MB** (791 MB headroom)

**Notes:**
- Kokoro is the clear speed winner by a massive margin
- Chatterbox is usable for longer text (RTF < 1 at sentence+ length); 4.6s for short phrases is the main drawback
- Parler-TTS is too slow for real-time streaming (always RTF > 1) but worth evaluating quality
- Fish Speech was skipped due to hard dependency on torch==2.8.0 (conflicts with Chatterbox)
- MeloTTS was skipped due to Python 3.12 / transformers version conflicts

---

## Next Steps (in order)

1. [ ] Install CUDA toolkit + PyTorch in WSL
2. [ ] Verify GPU access: `nvidia-smi` + torch CUDA test
3. [ ] Deploy Kokoro-FastAPI (baseline test)
4. [ ] Deploy Chatterbox server (quality test)
5. [ ] Optional: Test Orpheus INT8 quantized
6. [ ] Review audio output, pick winner
7. [ ] Register as permanent service:
   - Add port 3004 to `~/.cloudflared/config.yml`
   - Run `cloudflared tunnel route dns willo tts.chriswa.com`
   - Add `watch_service` entry to `~/nssm-wsl-startup.sh`
8. [ ] Update `willow-infra` skill with TTS service details
