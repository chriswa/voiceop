"""
Orpheus TTS Server — port 3009
Apache 2.0, Llama-3B + SNAC codec
INT8 quantization via bitsandbytes (~3.2 GB VRAM).
8 built-in voices. Starts UNLOADED.
"""
import io, wave, time, threading, gc
import numpy as np
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse, JSONResponse
import uvicorn

MODEL_ID = "canopyai/Orpheus-3B-0.1-ft"
SAMPLE_RATE = 24000

VOICES = ["tara", "leah", "jess", "leo", "dan", "mia", "zac", "zoe"]

_lock   = threading.Lock()
_loaded = False
_model      = None
_tokenizer  = None
_snac_model = None
_device     = None

def _cors():
    return {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Expose-Headers":
            "X-TTFA-MS,X-Total-MS,X-RTF,X-Audio-Duration,X-Streaming,X-Model,X-Voice",
    }

# ── inference helpers ──────────────────────────────────────────────────────────
def _tokens_to_audio(tokens):
    """Convert Orpheus token stream to waveform via SNAC codec."""
    import torch

    # Filter to audio tokens (Orpheus uses token IDs 32002–32258 for SNAC)
    audio_tokens = [t - 32002 for t in tokens if 32002 <= t <= 32258]
    if not audio_tokens:
        return np.zeros(100, dtype=np.float32)

    # SNAC expects 3 code streams; Orpheus interleaves them as [l0, l1, l2, l1, l2, l1, l2, …]
    # Simplest valid decode: reshape into layers
    # Orpheus outputs groups of 7 tokens per frame: 1×l0 + 2×l1 + 4×l2
    n = len(audio_tokens)
    # Trim to multiple of 7
    n = (n // 7) * 7
    if n == 0:
        return np.zeros(100, dtype=np.float32)
    audio_tokens = audio_tokens[:n]

    codes_0, codes_1, codes_2 = [], [], []
    for i in range(0, n, 7):
        codes_0.append(audio_tokens[i])
        codes_1.append(audio_tokens[i+1])
        codes_1.append(audio_tokens[i+4])
        codes_2.append(audio_tokens[i+2])
        codes_2.append(audio_tokens[i+3])
        codes_2.append(audio_tokens[i+5])
        codes_2.append(audio_tokens[i+6])

    codes = [
        torch.tensor(codes_0, dtype=torch.long).unsqueeze(0).to(_device),
        torch.tensor(codes_1, dtype=torch.long).unsqueeze(0).to(_device),
        torch.tensor(codes_2, dtype=torch.long).unsqueeze(0).to(_device),
    ]
    with torch.no_grad():
        audio_hat = _snac_model.decode(codes)
    return audio_hat.squeeze().cpu().float().numpy()

def _synthesize(text: str, voice: str) -> np.ndarray:
    import torch

    prompt = f"<|audio|>{voice}: {text}<|eot_id|>"
    inputs = _tokenizer(prompt, return_tensors="pt").to(_device)

    with torch.no_grad():
        output = _model.generate(
            **inputs,
            max_new_tokens=1200,
            do_sample=True,
            temperature=0.6,
            top_p=0.9,
            repetition_penalty=1.1,
        )

    # Extract newly generated tokens only
    new_tokens = output[0][inputs["input_ids"].shape[1]:].tolist()
    return _tokens_to_audio(new_tokens)

# ── load / unload ──────────────────────────────────────────────────────────────
def _load():
    global _model, _tokenizer, _snac_model, _loaded, _device
    import torch
    from transformers import AutoTokenizer, AutoModelForCausalLM, BitsAndBytesConfig
    from snac import SNAC

    _device = "cuda" if torch.cuda.is_available() else "cpu"

    quantization_config = BitsAndBytesConfig(load_in_8bit=True)

    _tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)

    _model = AutoModelForCausalLM.from_pretrained(
        MODEL_ID,
        quantization_config=quantization_config,
        device_map="auto",
    )

    _snac_model = SNAC.from_pretrained("hubertsiuzdak/snac_24khz").eval().to(_device)

    _loaded = True

def _unload():
    global _model, _tokenizer, _snac_model, _loaded
    _model      = None
    _tokenizer  = None
    _snac_model = None
    _loaded     = False
    try:
        import torch
        torch.cuda.empty_cache()
        gc.collect()
    except Exception:
        pass

# ── app ────────────────────────────────────────────────────────────────────────
app = FastAPI()
print("Orpheus server starting (model not loaded — call POST /load)", flush=True)

@app.get("/health")
def health():
    try:
        import torch
        vram = torch.cuda.memory_allocated() / 1024**2 if _loaded else 0
    except Exception:
        vram = 0
    return {
        "status":  "ok" if _loaded else "unloaded",
        "model":   "orpheus-3b-int8",
        "loaded":  _loaded,
        "vram_mb": round(vram),
    }

@app.get("/voices")
def voices():
    return {
        "voices": VOICES,
        "model":  "orpheus-3b-int8",
        "note":   "8 built-in voices; no VRAM cost to switch",
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
    voice = body.get("voice", "tara")
    if voice not in VOICES:
        voice = "tara"

    t_start = time.perf_counter()
    try:
        audio = _synthesize(text, voice)
    except Exception as e:
        return JSONResponse({"error": str(e)}, status_code=500, headers=_cors())
    t_end = time.perf_counter()

    audio_i16 = (np.clip(audio, -1, 1) * 32767).astype(np.int16)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1); wf.setsampwidth(2); wf.setframerate(SAMPLE_RATE)
        wf.writeframes(audio_i16.tobytes())
    buf.seek(0)

    dur = len(audio) / SAMPLE_RATE
    ms  = (t_end - t_start) * 1000
    rtf = (t_end - t_start) / dur if dur > 0 else 0

    return StreamingResponse(buf, media_type="audio/wav", headers={
        **_cors(),
        "X-Streaming":      "false",
        "X-TTFA-MS":        f"{ms:.0f}",
        "X-Total-MS":       f"{ms:.0f}",
        "X-RTF":            f"{rtf:.3f}",
        "X-Audio-Duration": f"{dur:.2f}",
        "X-Model":          "orpheus-3b-int8",
        "X-Voice":          voice,
    })

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=3009, log_level="warning")
