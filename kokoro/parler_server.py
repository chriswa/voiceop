"""
Parler-TTS Server — port 3007
MIT license, transformer-based, prompt-controlled speaker style
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
_tokenizer = None
_device = "cuda:0" if torch.cuda.is_available() else "cpu"
_dtype  = torch.float16 if torch.cuda.is_available() else torch.float32
MODEL_ID = "parler-tts/parler-tts-mini-v1"

VOICES = {
    "laura":   "Laura's voice is expressive and dramatic in delivery, with a slightly fast-paced and very close recording that has no background noise.",
    "gary":    "Gary speaks with a slightly expressive and animated tone. The recording is very close with no background noise.",
    "jon":     "Jon speaks at a moderate pace with a clear and articulate voice. The audio quality is crisp and professional.",
    "lea":     "Lea's voice is calm and measured, with very clear diction, a close recording, and no background noise.",
    "rose":    "Rose has a warm and friendly voice with a natural American accent, speaking at a comfortable conversational pace with clear pronunciation.",
    "will":    "Will has a deep, authoritative voice speaking slowly and clearly with a formal professional tone and excellent articulation.",
    "sophie":  "Sophie speaks quickly with an upbeat, energetic delivery. Her voice is light and clear, recorded in a bright, close setting.",
    "thomas":  "Thomas has a thoughtful, measured pace with a slightly British accent. His tone is calm and reassuring, recorded clearly.",
}

def _load():
    global _model, _tokenizer, _loaded
    from parler_tts import ParlerTTSForConditionalGeneration
    from transformers import AutoTokenizer
    _model     = ParlerTTSForConditionalGeneration.from_pretrained(MODEL_ID, torch_dtype=_dtype).to(_device)
    _tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
    _loaded    = True

def _unload():
    global _model, _tokenizer, _loaded
    _loaded    = False
    _model     = None
    _tokenizer = None
    torch.cuda.empty_cache()

print("Loading Parler-TTS model...", flush=True)
t0 = time.time()
_load()
print(f"Parler-TTS ready in {time.time()-t0:.1f}s | VRAM: {torch.cuda.memory_allocated()/1024**2:.0f} MB", flush=True)

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
    return {"status": "ok" if _loaded else "unloaded", "model": "parler-tts-mini-v1",
            "loaded": _loaded, "vram_mb": round(vram), "device": _device}

@app.get("/voices")
def voices_list():
    return {"voices": list(VOICES.keys()), "model": "parler-tts-mini-v1",
            "note": "Voice style controlled by natural language description — no extra VRAM cost"}

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
    body  = await request.json()
    text  = body.get("text", "")
    voice = body.get("voice", "laura")
    desc  = VOICES.get(voice, VOICES["laura"])

    t_start = time.perf_counter()
    input_ids  = _tokenizer(desc, return_tensors="pt").input_ids.to(_device)
    prompt_ids = _tokenizer(text, return_tensors="pt").input_ids.to(_device)
    with torch.no_grad():
        gen = _model.generate(input_ids=input_ids, prompt_input_ids=prompt_ids)
    t_end = time.perf_counter()

    audio = gen.cpu().numpy().squeeze()
    sr    = _model.config.sampling_rate
    audio_i16 = (np.clip(audio, -1, 1) * 32767).astype(np.int16)
    buf = io.BytesIO()
    with wave.open(buf, 'wb') as wf:
        wf.setnchannels(1); wf.setsampwidth(2); wf.setframerate(sr)
        wf.writeframes(audio_i16.tobytes())
    buf.seek(0)

    dur = len(audio) / sr
    ms  = (t_end - t_start) * 1000
    rtf = (t_end - t_start) / dur if dur > 0 else 0

    return StreamingResponse(buf, media_type="audio/wav", headers={
        **_cors(),
        "X-Streaming":      "false",
        "X-TTFA-MS":        f"{ms:.0f}",
        "X-Total-MS":       f"{ms:.0f}",
        "X-RTF":            f"{rtf:.3f}",
        "X-Audio-Duration": f"{dur:.2f}",
        "X-Model":          "parler-tts-mini-v1",
        "X-Voice":          voice,
    })

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=3007, log_level="warning")
