"""
Chatterbox TTS Server — port 3006
MIT license, 0.5B params, ~3 GB VRAM, emotion control
Non-streaming — generates all audio then sends.
"""
import io, wave, time, threading
import numpy as np
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse, JSONResponse
import uvicorn, torch

# ── model state ───────────────────────────────────────────────────────────────
_lock = threading.Lock()
_loaded = False
_model = None
_device = "cuda" if torch.cuda.is_available() else "cpu"

def _load():
    global _model, _loaded
    from chatterbox.tts import ChatterboxTTS
    _model = ChatterboxTTS.from_pretrained(device=_device)
    _loaded = True

def _unload():
    global _model, _loaded
    _loaded = False
    _model = None
    torch.cuda.empty_cache()

print("Loading Chatterbox model...", flush=True)
t0 = time.time()
_load()
print(f"Chatterbox ready in {time.time()-t0:.1f}s | VRAM: {torch.cuda.memory_allocated()/1024**2:.0f} MB", flush=True)

VOICES = ["default"]  # voice cloning needs reference audio; default = no reference

def _cors():
    return {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Expose-Headers":
            "X-TTFA-MS,X-Total-MS,X-RTF,X-Audio-Duration,X-Streaming,X-Model,X-Voice",
    }

app = FastAPI()

@app.get("/health")
def health():
    vram = torch.cuda.memory_allocated()/1024**2 if _loaded else 0
    return {"status": "ok" if _loaded else "unloaded", "model": "chatterbox-0.5b",
            "loaded": _loaded, "vram_mb": round(vram), "device": _device}

@app.get("/voices")
def voices():
    return {"voices": VOICES, "model": "chatterbox-0.5b",
            "note": "Voice cloning available with reference audio — API extension needed"}

@app.post("/load")
def load():
    with _lock:
        if _loaded:
            return {"status": "already_loaded", "vram_mb": round(torch.cuda.memory_allocated()/1024**2)}
        t0 = time.time()
        _load()
        ms = (time.time()-t0)*1000
    return {"status": "loaded", "load_time_ms": round(ms),
            "vram_mb": round(torch.cuda.memory_allocated()/1024**2)}

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
        return JSONResponse({"error": "model not loaded — call /load first"}, status_code=503,
                            headers=_cors())
    body = await request.json()
    text        = body.get("text", "")
    exaggeration = float(body.get("exaggeration", 0.5))

    t_start = time.perf_counter()
    wav = _model.generate(text, exaggeration=exaggeration)
    t_end = time.perf_counter()

    audio = wav.squeeze().cpu().numpy()
    sr = _model.sr
    audio_i16 = (np.clip(audio, -1, 1) * 32767).astype(np.int16)
    buf = io.BytesIO()
    with wave.open(buf, 'wb') as wf:
        wf.setnchannels(1); wf.setsampwidth(2); wf.setframerate(sr)
        wf.writeframes(audio_i16.tobytes())
    buf.seek(0)

    dur  = len(audio) / sr
    ms   = (t_end - t_start) * 1000
    rtf  = (t_end - t_start) / dur if dur > 0 else 0

    return StreamingResponse(buf, media_type="audio/wav", headers={
        **_cors(),
        "X-Streaming":      "false",
        "X-TTFA-MS":        f"{ms:.0f}",
        "X-Total-MS":       f"{ms:.0f}",
        "X-RTF":            f"{rtf:.3f}",
        "X-Audio-Duration": f"{dur:.2f}",
        "X-Model":          "chatterbox-0.5b",
        "X-Voice":          "default",
    })

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=3006, log_level="warning")
