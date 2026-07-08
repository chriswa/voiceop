"""
Fish Speech S2 Server — port 3008
CC-BY-NC-SA 4.0 (personal use OK)
~5 GB VRAM. Starts UNLOADED — call POST /load to activate.

Wraps fish-speech's Python inference API directly.
Model weights are downloaded on first /load call.
"""
import io, struct, wave, time, threading, gc
import numpy as np
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse, JSONResponse
import uvicorn

FISH_SRC   = "/home/willo/acp-host-projects/tts/fish-speech-src"
CKPT_PATH  = f"{FISH_SRC}/checkpoints/s2-pro"
CODEC_PATH = f"{CKPT_PATH}/codec.pth"
MODEL_ID   = "fishaudio/s2-pro"  # HuggingFace model for download

# ── state ─────────────────────────────────────────────────────────────────────
_lock   = threading.Lock()
_loaded = False
_engine = None  # TTSInferenceEngine

import sys, os
sys.path.insert(0, FISH_SRC)

def _cors():
    return {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Expose-Headers":
            "X-TTFA-MS,X-Total-MS,X-RTF,X-Audio-Duration,X-Streaming,X-Model,X-Voice",
    }

# ── load / unload ──────────────────────────────────────────────────────────────
def _ensure_weights():
    """Download model weights if not present."""
    import os
    if os.path.exists(CKPT_PATH) and len(os.listdir(CKPT_PATH)) > 2:
        return True
    print(f"Downloading Fish Speech weights to {CKPT_PATH}…", flush=True)
    os.makedirs(CKPT_PATH, exist_ok=True)
    try:
        from huggingface_hub import snapshot_download
        snapshot_download(MODEL_ID, local_dir=CKPT_PATH)
        return True
    except Exception as e:
        print(f"Download failed: {e}", flush=True)
        return False

def _load():
    global _engine, _loaded
    import torch
    if not _ensure_weights():
        raise RuntimeError("Model weights not available")

    from fish_speech.models.dac.inference import load_model as load_decoder
    from fish_speech.models.text2semantic.inference import launch_thread_safe_queue
    from fish_speech.inference_engine import TTSInferenceEngine

    device    = "cuda" if torch.cuda.is_available() else "cpu"
    precision = torch.bfloat16

    llama_queue = launch_thread_safe_queue(
        checkpoint_path=CKPT_PATH,
        device=device,
        precision=precision,
        compile=False,
    )
    decoder = load_decoder(
        config_name="modded_dac_vq",
        checkpoint_path=CODEC_PATH,
        device=device,
    )
    _engine = TTSInferenceEngine(
        llama_queue=llama_queue,
        decoder_model=decoder,
        precision=precision,
        compile=False,
    )
    _loaded = True

def _unload():
    global _engine, _loaded
    _engine = None
    _loaded = False
    try:
        import torch
        torch.cuda.empty_cache()
        gc.collect()
    except Exception:
        pass

# ── app ────────────────────────────────────────────────────────────────────────
app = FastAPI()
print("Fish Speech server starting (model not loaded — call POST /load)", flush=True)

@app.get("/health")
def health():
    try:
        import torch
        vram = torch.cuda.memory_allocated() / 1024**2 if _loaded else 0
    except Exception:
        vram = 0
    return {
        "status":   "ok" if _loaded else "unloaded",
        "model":    "fish-speech-s2-pro",
        "loaded":   _loaded,
        "vram_mb":  round(vram),
    }

@app.get("/voices")
def voices():
    return {
        "voices": ["default"],
        "model":  "fish-speech-s2-pro",
        "note":   "Voice cloning available via reference audio upload (POST /v1/references/add)",
    }

@app.post("/load")
def load():
    with _lock:
        if _loaded:
            import torch
            return {"status": "already_loaded",
                    "vram_mb": round(torch.cuda.memory_allocated()/1024**2)}
        t0 = time.time()
        try:
            _load()
        except Exception as e:
            return JSONResponse({"error": str(e)}, status_code=500)
        ms = (time.time() - t0) * 1000
    try:
        import torch
        vram = round(torch.cuda.memory_allocated()/1024**2)
    except Exception:
        vram = 0
    return {"status": "loaded", "load_time_ms": round(ms), "vram_mb": vram}

@app.post("/unload")
def unload():
    with _lock:
        if not _loaded:
            return {"status": "already_unloaded"}
        _unload()
    return {"status": "unloaded", "vram_mb": 0}

@app.options("/synthesize")
def synthesize_opts():
    return JSONResponse({}, headers={**_cors(),
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type"})

@app.post("/synthesize")
async def synthesize(request: Request):
    if not _loaded:
        return JSONResponse({"error": "model not loaded — call POST /load first"},
                            status_code=503, headers=_cors())
    body  = await request.json()
    text  = body.get("text", "")

    from fish_speech.utils.schema import ServeTTSRequest
    req = ServeTTSRequest(text=text, format="wav", streaming=False)

    t_start = time.perf_counter()
    result  = None
    for r in _engine.inference(req):
        if r.code in ("final", "segment"):
            result = r
        if r.code == "error":
            return JSONResponse({"error": str(r.error)}, status_code=500,
                                headers=_cors())
    t_end = time.perf_counter()

    if result is None or result.audio is None:
        return JSONResponse({"error": "No audio generated"}, status_code=500,
                            headers=_cors())

    sample_rate, audio = result.audio
    audio_i16 = (np.clip(audio, -1, 1) * 32767).astype(np.int16)

    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1); wf.setsampwidth(2); wf.setframerate(sample_rate)
        wf.writeframes(audio_i16.tobytes())
    buf.seek(0)

    dur = len(audio) / sample_rate
    ms  = (t_end - t_start) * 1000
    rtf = (t_end - t_start) / dur if dur > 0 else 0

    return StreamingResponse(buf, media_type="audio/wav", headers={
        **_cors(),
        "X-Streaming":      "false",
        "X-TTFA-MS":        f"{ms:.0f}",
        "X-Total-MS":       f"{ms:.0f}",
        "X-RTF":            f"{rtf:.3f}",
        "X-Audio-Duration": f"{dur:.2f}",
        "X-Model":          "fish-speech-s2-pro",
        "X-Voice":          "default",
    })

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=3008, log_level="warning")
