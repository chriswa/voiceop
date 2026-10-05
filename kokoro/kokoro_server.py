"""
Kokoro TTS — single combined server, port 3004.

Serves BOTH the synthesis API and the public web UI (tts.chriswa.com) from one
process. This replaced a two-process design (a separate Bun UI/proxy server +
a bash supervisor that arbitrated between up to 5 different TTS engines) —
once Kokoro was chosen as the only engine we're keeping, always-loaded and
never switched, that supervision layer was pure overhead. See
../Research/CRASH_LOG_2026-07-04.md and CRASH_REPORT_2026-07-05.md for the
history that led here (host RAM exhaustion from running many heavy engines
at once; this design structurally can't repeat that — there is exactly one
model, loaded once, for the life of the process).

Apache 2.0, 82M params, ~550 MB VRAM. True streaming: yields PCM chunks as
generated. TTFA is measured client-side from the first REAL AUDIO byte
(the WAV header is flushed near-instantly and contains no sound — timing
off of it wildly understates real time-to-first-sound; see conversation
history for how that bug was found and fixed).

Language support: Kokoro ships 54 voices across 9 language codes, but 'j'
(Japanese) and 'z' (Mandarin) require extra packages (pyopenjtalk,
misaki[zh]) that aren't installed. Deliberately scoped to the 7 languages
that work with what's already here (English x2, Spanish, French, Hindi,
Italian, Portuguese) = 41 voices. Add pyopenjtalk / misaki[zh] and the two
entries in LANGUAGES below to extend.
"""
import struct, time, threading, json, os, asyncio

def _load_dotenv(path=".env"):
    # Minimal .env loader (no dependency): KEY=VALUE lines, '#' comments.
    # Real environment variables always win over the file, so an explicit
    # `PORT=... python kokoro_server.py` still overrides the .env. This lets
    # the primary install keep its hard-coded 3004 default while a per-machine
    # .env picks a non-conflicting port.
    try:
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), path)) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                os.environ.setdefault(key.strip(), val.strip().strip('"').strip("'"))
    except FileNotFoundError:
        pass

_load_dotenv()

import numpy as np
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse, JSONResponse, HTMLResponse
from starlette.concurrency import run_in_threadpool
import uvicorn, torch

SAMPLE_RATE = 24000
REPO_ID = "hexgrad/Kokoro-82M"
MAX_TEXT_LEN = 5000
# Kokoro's KPipeline.__call__ takes a real `speed` param that's applied during
# generation itself (it stretches/compresses the predicted duration per
# phoneme before vocoding) — not a post-hoc playback-rate hack, so speeding
# up happens on the backend and the client gets audio already at the
# requested pace. 0.5-2.0 covers Kokoro's practically-useful range before
# quality degrades noticeably.
MIN_SPEED = 0.5
MAX_SPEED = 2.0
DEFAULT_SPEED = 1.2

# ── egress pacing toggle ────────────────────────────────────────────────────────
# When on, /synthesize meters audio out at ~1.3x realtime (see the long note in
# synthesize()). That smooths a lossy WAN hop (phone -> Cloudflare Tunnel -> the
# production box), but on a machine whose only client is local it just throttles
# delivery of audio that's already generated far faster than realtime — turning a
# ~0.4s job into a multi-second trickle and starving the client's prefetch. So
# it's a switch, defaulting ON to preserve the production install (which has no
# .env and relies on defaults); the Mac's .env sets KOKORO_EGRESS_PACING=off.
# Deliberately NOT auto-detected by client IP: cloudflared runs on the production
# box, so genuinely-remote requests arrive from 127.0.0.1 there too.
def _env_flag(name: str, default: bool) -> bool:
    v = os.environ.get(name)
    if v is None:
        return default
    return v.strip().lower() not in ("0", "off", "false", "no", "")

EGRESS_PACING = _env_flag("KOKORO_EGRESS_PACING", True)

# ── language / voice catalog ───────────────────────────────────────────────────
# lang_code -> human label. Only languages usable with currently-installed
# deps (misaki[en] + system espeak-ng). See module docstring.
LANGUAGES = {
    "a": "American English",
    "b": "British English",
    "e": "Spanish",
    "f": "French",
    "h": "Hindi",
    "i": "Italian",
    "p": "Portuguese (Brazilian)",
}
GENDERS = {"f": "female", "m": "male"}

# Full 54-voice list from the hexgrad/Kokoro-82M repo; voices whose language
# prefix isn't in LANGUAGES (Japanese jf_/jm_, Mandarin zf_/zm_) are filtered
# out automatically below rather than listed as unsupported entries.
_ALL_VOICE_IDS = [
    "af_alloy","af_aoede","af_bella","af_heart","af_jessica","af_kore","af_nicole",
    "af_nova","af_river","af_sarah","af_sky",
    "am_adam","am_echo","am_eric","am_fenrir","am_liam","am_michael","am_onyx",
    "am_puck","am_santa",
    "bf_alice","bf_emma","bf_isabella","bf_lily",
    "bm_daniel","bm_fable","bm_george","bm_lewis",
    "ef_dora","em_alex","em_santa",
    "ff_siwis",
    "hf_alpha","hf_beta","hm_omega","hm_psi",
    "if_sara","im_nicola",
    "jf_alpha","jf_gongitsune","jf_nezumi","jf_tebukuro","jm_kumo",
    "pf_dora","pm_alex","pm_santa",
    "zf_xiaobei","zf_xiaoni","zf_xiaoxiao","zf_xiaoyi","zm_yunjian","zm_yunxi",
    "zm_yunxia","zm_yunyang",
]

def _voice_catalog():
    out = []
    for vid in _ALL_VOICE_IDS:
        lang_code, gender_code, name = vid[0], vid[1], vid[3:]
        if lang_code not in LANGUAGES:
            continue
        out.append({
            "id": vid,
            "lang_code": lang_code,
            "language": LANGUAGES[lang_code],
            "gender": GENDERS.get(gender_code, "?"),
            # Language is deliberately left out here — the dropdown already
            # groups voices under a language <optgroup> heading, so repeating
            # it in every option's label was pure redundancy. Gender stays,
            # since that's not otherwise visible at a glance.
            "label": f"{name.capitalize()} ({GENDERS.get(gender_code, '?')})",
        })
    return out

VOICES = _voice_catalog()
VOICE_IDS = {v["id"] for v in VOICES}
DEFAULT_VOICE = "af_heart"

# ── voice block list ────────────────────────────────────────────────────────────
# UI-only feature: lets you permanently hide a voice from the dropdown/`/voices`
# response once you've decided it doesn't sound good. Purely a filter — voice
# definitions above are untouched, and this is just a small JSON file of ids
# sitting next to the script so it survives restarts.
BLOCKLIST_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "blocked_voices.json")
_blocklist_lock = threading.Lock()

def _load_blocklist() -> set:
    try:
        with open(BLOCKLIST_FILE) as f:
            return {v for v in json.load(f) if v in VOICE_IDS}
    except (FileNotFoundError, json.JSONDecodeError):
        return set()

def _save_blocklist():
    with open(BLOCKLIST_FILE, "w") as f:
        json.dump(sorted(BLOCKED_VOICES), f, indent=2)

BLOCKED_VOICES = _load_blocklist()

def _active_voices():
    return [v for v in VOICES if v["id"] not in BLOCKED_VOICES]

# ── model / pipeline state ──────────────────────────────────────────────────────
# One shared KModel (the actual weights, the only thing that's expensive),
# reused across a lazily-built KPipeline per language (cheap G2P wrapper).
# This is what lets 41 voices across 7 languages share a single ~550MB VRAM
# footprint instead of multiplying it per language.
_pipeline_lock = threading.Lock()
# PyTorch MPS is not safe to enter concurrently from multiple Python worker
# threads. The crash report from 2026-07-28 showed two synthesis workers in
# MetalShaderLibrary's unary-kernel cache when one segfaulted. Keep network
# streaming concurrent, but serialize only the next() call that executes model
# work. CUDA and CPU are also safe with this conservative policy.
_inference_lock = threading.Lock()
_request_lock = threading.Lock()
_next_request_id = 0
_model = None
_pipelines = {}

def _new_request_id():
    global _next_request_id
    with _request_lock:
        _next_request_id += 1
        return _next_request_id

def _pick_device():
    # Allow explicit override (e.g. KOKORO_DEVICE=cpu on a flaky MPS backend).
    forced = os.environ.get("KOKORO_DEVICE")
    if forced:
        return forced
    if torch.cuda.is_available():
        return "cuda"
    # Apple Silicon: MPS gives a big speedup over CPU for the 82M model.
    if getattr(torch.backends, "mps", None) is not None and torch.backends.mps.is_available():
        return "mps"
    return "cpu"

def _vram_mb():
    # Only CUDA exposes an allocator query; other backends report 0.
    if torch.cuda.is_available():
        return torch.cuda.memory_allocated() / 1024**2
    return 0.0

def _advance(gen):
    """Run one model step of a KPipeline generator. The only place model work
    executes, so both concerns about MPS live here:

    - Concurrency: hold _inference_lock across the step only, so other requests
      can stream/pace concurrently while MPS is never entered from two threads.
    - Memory: PyTorch caches a compiled MPSGraph per distinct tensor shape, and
      the vocoder's shapes follow the audio length, so every new utterance
      length adds ~40 MB that is never evicted (pytorch/pytorch #181213). As of
      torch 2.14, empty_cache() reclaims it; it costs nothing measurable per
      request (recompiling is cheaper than the leak's own slowdown). Done under
      the lock so no other step's graphs are in flight.

    Returns (result or None when exhausted, ms spent waiting for the lock)."""
    wait_started = time.monotonic()
    with _inference_lock:
        waited_ms = (time.monotonic() - wait_started) * 1000
        result = next(gen, None)
        if _model is not None and _model.device.type == "mps":
            torch.mps.synchronize()
            torch.mps.empty_cache()
    return result, waited_ms

def _get_model():
    global _model
    if _model is None:
        from kokoro import KModel
        _model = KModel(repo_id=REPO_ID).to(_pick_device()).eval()
    return _model

def _get_pipeline(lang_code: str):
    with _pipeline_lock:
        if lang_code not in _pipelines:
            from kokoro import KPipeline
            _pipelines[lang_code] = KPipeline(lang_code=lang_code, repo_id=REPO_ID, model=_get_model())
        return _pipelines[lang_code]

# ── duration-only model (for /timestamps) ────────────────────────────────────────
# Word timings come entirely from Kokoro's `pred_dur`, which the model computes
# *before* the vocoder — and the vocoder is ~76% of a synthesis pass on this box.
# This wraps the shared KModel and runs only the duration-predictor half, so
# /timestamps costs ~1/4 of a full synth and stops competing with real audio work
# on the inference lock. It exposes the few attributes KPipeline reads (device,
# vocab, context_length) plus a KModel-compatible __call__, so it drops straight
# into KPipeline.__call__(..., model=<this>). It mirrors KModel.forward /
# forward_with_tokens up to pred_dur (kokoro 0.9.x internals); if that path ever
# raises, _word_timings falls back to a full synthesis pass, so a library change
# costs speed here, never correct timings.
_duration_model = None

class _DurationOnlyModel:
    def __init__(self, model):
        self._m = model
        self.device = model.device
        self.vocab = model.vocab
        self.context_length = model.context_length

    @torch.no_grad()
    def __call__(self, phonemes, ref_s, speed=1, return_output=False):
        from kokoro import KModel
        m = self._m
        input_ids = [i for i in (m.vocab.get(p) for p in phonemes) if i is not None]
        assert len(input_ids) + 2 <= m.context_length
        input_ids = torch.LongTensor([[0, *input_ids, 0]]).to(m.device)
        ref_s = ref_s.to(m.device)
        input_lengths = torch.full((input_ids.shape[0],), input_ids.shape[-1],
                                   device=input_ids.device, dtype=torch.long)
        text_mask = torch.arange(input_lengths.max()).unsqueeze(0)
        text_mask = text_mask.expand(input_lengths.shape[0], -1).type_as(input_lengths)
        text_mask = torch.gt(text_mask + 1, input_lengths.unsqueeze(1)).to(m.device)
        bert_dur = m.bert(input_ids, attention_mask=(~text_mask).int())
        d_en = m.bert_encoder(bert_dur).transpose(-1, -2)
        s = ref_s[:, 128:]
        d = m.predictor.text_encoder(d_en, s, input_lengths, text_mask)
        x, _ = m.predictor.lstm(d)
        duration = m.predictor.duration_proj(x)
        duration = torch.sigmoid(duration).sum(axis=-1) / speed
        pred_dur = torch.round(duration).clamp(min=1).long().squeeze().cpu()
        return KModel.Output(audio=None, pred_dur=pred_dur) if return_output else None

def _get_duration_model():
    global _duration_model
    if _duration_model is None:
        _duration_model = _DurationOnlyModel(_get_model())
    return _duration_model

# ── startup: always loaded, no /load or /unload — this is the only engine we
# run, so there's no reason to ever have it not ready.
print("Loading Kokoro model...", flush=True)
_t0 = time.time()
_get_model()
_get_pipeline("a")   # preload the default/most-likely-used language eagerly
print(f"Kokoro ready in {time.time()-_t0:.1f}s | device: {_pick_device()} | VRAM: {_vram_mb():.0f} MB", flush=True)

# ── helpers ───────────────────────────────────────────────────────────────────
def _wav_stream_header(sample_rate=SAMPLE_RATE, channels=1, bits=16) -> bytes:
    """WAV header with 0xFFFFFFFF sizes for streaming (unknown length up front)."""
    byte_rate = sample_rate * channels * (bits // 8)
    block_align = channels * (bits // 8)
    return struct.pack('<4sI4s4sIHHIIHH4sI',
        b'RIFF', 0xFFFFFFFF, b'WAVE',
        b'fmt ', 16, 1, channels, sample_rate,
        byte_rate, block_align, bits,
        b'data', 0xFFFFFFFF)

class _BadParams(Exception):
    """A caller supplied invalid synthesis parameters; the message is safe to
    hand straight back to the client as a 400."""

def _parse_synth_params(body: dict):
    """Validate the shared {text, voice, speed} request body used by both
    /synthesize and /timestamps. Returns the cleaned (text, voice, speed) or
    raises _BadParams with a client-facing message. Single source of truth so
    the two endpoints can't drift on what they accept."""
    text  = (body.get("text") or "").strip()
    voice = body.get("voice", DEFAULT_VOICE)
    speed = body.get("speed", DEFAULT_SPEED)
    if not text:
        raise _BadParams("text is required")
    if len(text) > MAX_TEXT_LEN:
        raise _BadParams(f"text exceeds {MAX_TEXT_LEN} character limit")
    if voice not in VOICE_IDS:
        raise _BadParams(f"unknown voice '{voice}'")
    if voice in BLOCKED_VOICES:
        raise _BadParams(f"voice '{voice}' is block-listed")
    try:
        speed = float(speed)
    except (TypeError, ValueError):
        raise _BadParams("speed must be a number")
    if not (MIN_SPEED <= speed <= MAX_SPEED):
        raise _BadParams(f"speed must be between {MIN_SPEED} and {MAX_SPEED}")
    return text, voice, speed

def _cors(request: Request | None = None):
    # A bare "*" is rejected by browsers on credentialed requests (fetch with
    # credentials:'include', which callers need in order to send the
    # Cloudflare Access session cookie cross-origin to this host). Reflecting
    # the specific request Origin + Allow-Credentials is the standard fix,
    # and is safe here since this endpoint has no cookie-based state of its
    # own to leak (Cloudflare Access is the actual authZ boundary in front of
    # this app).
    origin = request.headers.get("origin") if request is not None else None
    headers = {
        "Access-Control-Expose-Headers":
            "X-TTFA-MS,X-Total-MS,X-RTF,X-Audio-Duration,X-Streaming,X-Model,X-Voice,X-Speed",
    }
    if origin:
        headers["Access-Control-Allow-Origin"] = origin
        headers["Access-Control-Allow-Credentials"] = "true"
        headers["Vary"] = "Origin"
    else:
        headers["Access-Control-Allow-Origin"] = "*"
    return headers

# ── app ───────────────────────────────────────────────────────────────────────
app = FastAPI()

@app.get("/health")
def health():
    return {"status": "ok", "model": "kokoro-82m", "loaded": True, "vram_mb": round(_vram_mb())}

@app.get("/voices")
def voices():
    active = _active_voices()
    default = DEFAULT_VOICE if DEFAULT_VOICE not in BLOCKED_VOICES else (active[0]["id"] if active else None)
    return {"voices": active, "model": "kokoro-82m", "default": default}

@app.options("/synthesize")
def synthesize_opts(request: Request):
    return JSONResponse({}, headers={**_cors(request),
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type"})

@app.options("/voices/block")
def block_voice_opts(request: Request):
    return JSONResponse({}, headers={**_cors(request),
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type"})

@app.post("/voices/block")
async def block_voice(request: Request):
    """UI-only voice block list. Marks a voice id as blocked so it's dropped
    from future /voices responses (and refused by /synthesize). Persisted to
    BLOCKLIST_FILE so it survives restarts. Not reversible from the UI on
    purpose — this endpoint is a one-way "I never want to see this voice
    again" action; edit/delete the JSON file by hand to undo."""
    body = await request.json()
    voice = (body.get("voice") or "").strip()
    if voice not in VOICE_IDS:
        return JSONResponse({"error": f"unknown voice '{voice}'"}, status_code=400, headers=_cors(request))
    with _blocklist_lock:
        BLOCKED_VOICES.add(voice)
        _save_blocklist()
    return JSONResponse({"status": "ok", "blocked": sorted(BLOCKED_VOICES)}, headers=_cors(request))

@app.post("/synthesize")
async def synthesize(request: Request):
    body = await request.json()
    try:
        text, voice, speed = _parse_synth_params(body)
    except _BadParams as e:
        return JSONResponse({"error": str(e)}, status_code=400, headers=_cors(request))

    lang_code = voice[0]
    pipeline = _get_pipeline(lang_code)
    request_id = _new_request_id()
    request_started = time.monotonic()

    # ── egress pacing ────────────────────────────────────────────────────────
    # Measured with test_streaming.py: Kokoro generates far faster than real
    # time on this GPU (RTF ~0.02-0.5x even for 30+s of audio finishing in
    # well under a second), and for short inputs (no sentence-ending
    # punctuation) the pipeline yields the *entire* utterance as a single
    # chunk — there's no per-chunk generation lag to "buffer against"
    # locally. But naively `yield`ing that whole blob the instant it's ready
    # hands the ASGI server one huge write to push out as fast as the pipe
    # allows, which over a real WAN hop (phone/remote -> Cloudflare Tunnel ->
    # here) tends to front-load onto a cold TCP/QUIC congestion window: the
    # first ~10-14 packets (roughly the first ~300-500ms of 24kHz/16-bit
    # audio) go out immediately, then delivery stalls for a round trip while
    # the window grows, then the rest arrives in a second burst. That matches
    # the reported symptom exactly (bit of audio, sub-second pause, rest of
    # audio) even though generation itself was never the bottleneck.
    #
    # Fix: buffer the whole utterance server-side (cheap - it's fast), send
    # an initial chunk immediately so playback can start, then meter out the
    # remainder in small, evenly-paced writes close to real-time instead of
    # one firehose blast. This is what the client would otherwise have to do
    # itself (delay playback ~1s to build a safety margin) — doing it here
    # means every client (browser UI, curl, phone) gets smooth delivery for
    # free.
    INITIAL_BUFFER_MS = 1000   # always send at least this much immediately (or all of it, if shorter)
    PACE_CHUNK_MS = 200        # size of each subsequent metered write
    PACE_FACTOR = 0.8          # <1 = send a little ahead of real-time so client buffer keeps growing

    # ── incremental generation + disconnect cancellation ────────────────────
    # This used to synthesize the *entire* text in one blocking call before
    # any pacing/streaming happened at all — fine for short inputs, but for
    # a multi-minute script it means: (a) the whole audio sits in RAM as one
    # buffer before a single byte goes out, and (b) if the client disconnects
    # a few seconds in, there was no way to notice — the rest of the
    # (possibly minutes of) audio kept generating on the GPU for nothing.
    #
    # Fix: pull one chunk at a time from Kokoro's own pipeline generator
    # (KPipeline already splits text internally into <=510-phoneme,
    # roughly-sentence-sized units — that's its real hard limit, not
    # anything we impose) and check `request.is_disconnected()` between
    # chunks. A disconnect stops us from asking Kokoro for any *further*
    # sentences — it can't abort a model call already dispatched to the
    # threadpool/GPU, but that's bounded to one sentence's worth of work,
    # not the whole remaining tail of a long document.
    gen = pipeline(text, voice=voice, speed=speed)
    gen_exhausted = False

    async def _pull_more(buf: bytearray) -> bool:
        """Advance the pipeline by one chunk (one blocking model call, run
        off the event loop). Returns False once the pipeline is exhausted."""
        nonlocal gen_exhausted
        (result, waited_ms) = await run_in_threadpool(_advance, gen)
        if waited_ms >= 10:
            print(f"[tts {request_id}] inference lock wait={waited_ms:.0f}ms", flush=True)
        if result is None:
            gen_exhausted = True
            return False
        _, _, audio = result
        # Kokoro may return a torch.Tensor or numpy array depending on version
        if hasattr(audio, 'cpu'):
            audio = audio.cpu().numpy()
        buf.extend((audio * 32767).astype(np.int16).tobytes())
        return True

    async def generate():
        print(f"[tts {request_id}] start chars={len(text)} voice={voice} "
              f"speed={speed} pacing={'on' if EGRESS_PACING else 'off'}", flush=True)
        try:
            yield _wav_stream_header(SAMPLE_RATE)

            buf = bytearray()

            # ── unpaced fast path (local clients) ────────────────────────────
            # Nothing to smooth over a loopback pipe, and the client does its
            # own buffering: hand each generated chunk straight through the
            # instant it's ready. Delivery becomes generation-bound (~RTF), so
            # a whole sentence lands in a fraction of a second and the client
            # can prefetch far ahead.
            if not EGRESS_PACING:
                while not gen_exhausted:
                    if await request.is_disconnected():
                        return
                    del buf[:]
                    await _pull_more(buf)
                    if buf:
                        yield bytes(buf)
                return

            # ── paced path (remote/WAN clients) ──────────────────────────────
            bytes_per_ms = SAMPLE_RATE * 2 / 1000  # int16 mono

            def _aligned(n_bytes):
                n = int(n_bytes)
                return n - (n % 2)  # keep on a 16-bit sample boundary

        # Accumulate chunks until we have enough for the initial burst (or
        # the whole utterance is shorter than that and the pipeline's done).
            initial_n_target = _aligned(INITIAL_BUFFER_MS * bytes_per_ms)
            while len(buf) < initial_n_target and not gen_exhausted:
                if await request.is_disconnected():
                    return
                await _pull_more(buf)

            if not buf:
                return

            initial_n = _aligned(min(initial_n_target, len(buf)))
            yield bytes(buf[:initial_n])
            del buf[:initial_n]

            chunk_n = _aligned(PACE_CHUNK_MS * bytes_per_ms) or 2
            while buf or not gen_exhausted:
                if await request.is_disconnected():
                    return
                if len(buf) < chunk_n and not gen_exhausted:
                    await _pull_more(buf)
                    continue
                end = min(chunk_n, len(buf))
                if end == 0:
                    continue
                chunk = bytes(buf[:end])
                del buf[:end]
                yield chunk
                if buf or not gen_exhausted:
                    chunk_duration_sec = len(chunk) / 2 / SAMPLE_RATE
                    await asyncio.sleep(chunk_duration_sec * PACE_FACTOR)
        finally:
            elapsed_ms = (time.monotonic() - request_started) * 1000
            print(f"[tts {request_id}] finish elapsed={elapsed_ms:.0f}ms", flush=True)

    return StreamingResponse(generate(), media_type="audio/wav",
        headers={**_cors(request), "X-Streaming": "true", "X-Model": "kokoro-82m", "X-Voice": voice,
                 "X-Speed": str(speed)})

# ── word timestamps (for read-along / word-highlight overlays) ──────────────────
# Kokoro's duration predictor assigns a frame count to every phoneme *before*
# the vocoder runs, and KPipeline turns that into per-token start_ts/end_ts
# (see KPipeline.join_timestamps). We surface those as word-level timings so a
# client can highlight each word as it's spoken.
#
# This is a SEPARATE call from /synthesize rather than folded into that stream
# on purpose: /synthesize streams raw WAV bytes and its clients (the macOS app's
# PCM parser, the browser Web Audio path) depend on the body being nothing but
# audio. A word's end time isn't known until its audio chunk has been generated,
# so the full list can't be sent ahead of the audio without buffering the whole
# utterance and destroying time-to-first-audio. Keeping timings on their own
# JSON endpoint leaves the proven audio contract untouched; the client fires
# both requests together and drives its overlay off a playback clock. Timings
# are deterministic for a given (text, voice, speed) — the duration predictor
# runs in eval mode with no sampling — so the two responses stay in lock-step.
# pred_dur is in duration-predictor frames; join_timestamps counts half-frames
# against MAGIC_DIVISOR=80, i.e. seconds = frames / 40. We use the same relation
# to advance the cross-segment offset when there's no audio tensor to measure.
_FRAMES_PER_SECOND = 40.0

def _collect_timings(result, offset: float, words: list):
    """Pull one pipeline Result's per-word timings into `words`, shifted by the
    audio already emitted before it, and return the segment's own duration in
    seconds. Works whether `result` carries real audio (full synth) or only
    pred_dur (duration-only path)."""
    for t in (result.tokens or []):
        start, end = getattr(t, "start_ts", None), getattr(t, "end_ts", None)
        word = t.text or ""
        if start is None or end is None:
            continue
        if not any(ch.isalnum() for ch in word):
            continue
        words.append({"word": word,
                      "start": round(offset + start, 3),
                      "end": round(offset + end, 3)})
    audio = result.audio
    if audio is not None:
        return len(audio) / SAMPLE_RATE
    pred_dur = result.pred_dur
    if pred_dur is not None:
        return float(pred_dur.sum().item()) / _FRAMES_PER_SECOND
    return 0.0

def _run_timings(pipeline, model, text: str, voice: str, speed: float):
    """Drive `pipeline` with `model` and collect (words, duration_seconds).
    Steps through _advance like /synthesize, so a timing pass can't starve
    audio synthesis."""
    gen = pipeline(text, voice=voice, speed=speed, model=model)
    words, offset = [], 0.0  # offset = cumulative seconds of prior chunks
    while True:
        result, _ = _advance(gen)
        if result is None:
            break
        offset += _collect_timings(result, offset, words)
    return words, offset

def _word_timings(text: str, voice: str, speed: float):
    """Return (words, duration_seconds) for `text`. Each word is
    {"word", "start", "end"} in seconds from the utterance start; bare
    punctuation/whitespace tokens are dropped (their time falls between the
    surrounding words).

    Fast path runs only Kokoro's duration predictor (no vocoder — see
    _DurationOnlyModel), which is all word timings need. If those internals ever
    change and it raises, fall back to a full synthesis pass so timings stay
    correct."""
    pipeline = _get_pipeline(voice[0])
    try:
        return _run_timings(pipeline, _get_duration_model(), text, voice, speed)
    except Exception as e:
        print(f"[ts] duration-only path failed ({type(e).__name__}: {e}); "
              f"falling back to full synthesis", flush=True)
        return _run_timings(pipeline, None, text, voice, speed)

@app.options("/timestamps")
def timestamps_opts(request: Request):
    return JSONResponse({}, headers={**_cors(request),
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type"})

@app.post("/timestamps")
async def timestamps(request: Request):
    body = await request.json()
    try:
        text, voice, speed = _parse_synth_params(body)
    except _BadParams as e:
        return JSONResponse({"error": str(e)}, status_code=400, headers=_cors(request))

    request_id = _new_request_id()
    started = time.monotonic()
    print(f"[ts {request_id}] start chars={len(text)} voice={voice} speed={speed}", flush=True)
    words, duration = await run_in_threadpool(_word_timings, text, voice, speed)
    elapsed_ms = (time.monotonic() - started) * 1000
    print(f"[ts {request_id}] finish words={len(words)} dur={duration:.2f}s elapsed={elapsed_ms:.0f}ms", flush=True)
    return JSONResponse(
        {"model": "kokoro-82m", "voice": voice, "speed": speed,
         "sample_rate": SAMPLE_RATE, "duration": round(duration, 3), "words": words},
        headers={**_cors(request), "X-Model": "kokoro-82m", "X-Voice": voice, "X-Speed": str(speed)})

# ── web UI ──────────────────────────────────────────────────────────────────────
HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Kokoro TTS — tts.chriswa.com</title>
<style>
  :root {
    --bg: #0f1115; --card: #1a1d24; --border: #2a2e38; --text: #e8e8ec;
    --muted: #8b8f9a; --accent: #5b9dd9; --green: #4caf70; --orange: #d9a43b; --red: #d9534f;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 1.5rem; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    background: var(--bg); color: var(--text); display: flex; justify-content: center;
  }
  .wrap { width: 100%; max-width: 640px; }
  h1 { font-size: 1.3rem; margin: 0 0 0.25rem; }
  .sub { color: var(--muted); font-size: 0.85rem; margin: 0 0 1.25rem; }
  .card { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 1.25rem; }
  textarea {
    width: 100%; min-height: 8rem; resize: vertical; background: #11141a; color: var(--text);
    border: 1px solid var(--border); border-radius: 8px; padding: 0.75rem; font: inherit; font-size: 0.95rem;
  }
  .row { display: flex; gap: 0.6rem; margin-top: 0.75rem; align-items: center; flex-wrap: wrap; }
  select {
    flex: 1; min-width: 12rem; background: #11141a; color: var(--text); border: 1px solid var(--border);
    border-radius: 8px; padding: 0.5rem; font: inherit;
  }
  button {
    background: var(--accent); color: #fff; border: none; border-radius: 8px; padding: 0.6rem 1.2rem;
    font: inherit; font-weight: 600; cursor: pointer;
  }
  button:disabled { opacity: 0.5; cursor: default; }
  button.danger { background: #3a2426; color: var(--red); border: 1px solid #6b3a3d; }
  button.danger:hover:not(:disabled) { background: #4a2c2f; }
  .status-row { display: flex; align-items: center; gap: 0.5rem; margin-top: 1rem; font-size: 0.85rem; color: var(--muted); }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--muted); }
  .dot.ok { background: var(--green); }
  .dot.bad { background: var(--red); }
  .synth-status { margin-top: 0.75rem; font-size: 0.9rem; min-height: 1.2em; }
  .synth-status.generating { color: var(--orange); }
  .synth-status.done { color: var(--green); }
  .synth-status.error { color: var(--red); }
  .chips { margin-top: 0.5rem; display: flex; flex-wrap: wrap; gap: 0.4rem; }
  .chip {
    background: #11141a; border: 1px solid var(--border); border-radius: 999px; padding: 0.2rem 0.7rem;
    font-size: 0.78rem; color: var(--muted);
  }
  .chip.hi { color: var(--accent); border-color: var(--accent); }
  audio { width: 100%; margin-top: 0.9rem; display: none; }
  audio.visible { display: block; }
  .api-docs { margin-top: 1.5rem; }
  .api-docs h2 { font-size: 1.05rem; margin: 0 0 0.75rem; }
  .endpoint { margin-bottom: 1.1rem; }
  .endpoint:last-child { margin-bottom: 0; }
  .endpoint h3 { font-size: 0.9rem; margin: 0 0 0.35rem; font-family: ui-monospace, Menlo, Consolas, monospace; }
  .endpoint h3 .method { color: var(--green); margin-right: 0.5rem; }
  .endpoint p { margin: 0.3rem 0; font-size: 0.85rem; color: var(--muted); }
  .endpoint pre {
    background: #11141a; border: 1px solid var(--border); border-radius: 8px; padding: 0.7rem 0.85rem;
    overflow-x: auto; font-size: 0.8rem; margin: 0.4rem 0 0; white-space: pre-wrap; word-break: break-word;
  }
  .endpoint code { font-family: ui-monospace, Menlo, Consolas, monospace; }
  .endpoint table { border-collapse: collapse; margin-top: 0.4rem; font-size: 0.82rem; width: 100%; }
  .endpoint th, .endpoint td { text-align: left; padding: 0.25rem 0.6rem 0.25rem 0; vertical-align: top; }
  .endpoint th { color: var(--muted); font-weight: 600; }
</style>
</head>
<body>
<div class="wrap">
  <h1>Kokoro TTS</h1>
  <p class="sub">82M params &middot; Apache 2.0 &middot; tts.chriswa.com</p>
  <div class="card">
    <textarea id="text" placeholder="Type something to synthesize…">The quick brown fox jumps over the lazy dog.</textarea>
    <div class="row">
      <select id="voice"><option>Loading voices…</option></select>
      <label for="speed" style="font-size:0.85rem;color:var(--muted);">Speed</label>
      <input id="speed" type="number" min="0.5" max="2.0" step="0.1" value="1.2"
        style="width:4.5rem;background:#11141a;color:var(--text);border:1px solid var(--border);border-radius:8px;padding:0.5rem;font:inherit;">
      <button id="btn-play">&#9654; Speak</button>
      <button id="btn-block" class="danger" title="Permanently hide this voice from the list">&#128683; Block voice</button>
    </div>
    <div class="status-row">
      <div class="dot" id="dot"></div>
      <span id="engine-status">Checking engine…</span>
    </div>
    <div class="synth-status idle" id="syn"></div>
    <div class="chips" id="chips"></div>
    <audio controls id="audio"></audio>
  </div>

  <div class="card api-docs">
    <h2>API reference</h2>

    <div class="endpoint">
      <h3><span class="method">POST</span>/synthesize</h3>
      <p>Streams synthesized speech back as a <code>audio/wav</code> body (streaming PCM — playback can start before generation finishes; a proper duration-bearing WAV header is only knowable once the full file is buffered).</p>
      <table>
        <tr><th>field</th><th>type</th><th>notes</th></tr>
        <tr><td><code>text</code></td><td>string</td><td>required, max 5000 characters</td></tr>
        <tr><td><code>voice</code></td><td>string</td><td>a voice <code>id</code> from <code>/voices</code>, e.g. <code>af_heart</code>. Defaults to <code>af_heart</code> if omitted.</td></tr>
        <tr><td><code>speed</code></td><td>number</td><td>optional, 0.5-2.0, default 1.2. Applied during generation (not a post-hoc playback-rate trick) via Kokoro's native <code>speed</code> param.</td></tr>
      </table>
      <pre>curl -N -X POST https://tts.chriswa.com/synthesize \
  -H "Content-Type: application/json" \
  -d '{"text": "Hello there.", "voice": "af_heart", "speed": 1.2}' \
  --output speech.wav</pre>
      <p>Response headers: <code>X-TTFA-MS</code>, <code>X-Total-MS</code>, <code>X-RTF</code>, <code>X-Audio-Duration</code>, <code>X-Streaming</code>, <code>X-Model</code>, <code>X-Voice</code>, <code>X-Speed</code>.</p>
    </div>

    <div class="endpoint">
      <h3><span class="method">POST</span>/timestamps</h3>
      <p>Returns word-level timings for read-along / word-highlight overlays as JSON. Same body as <code>/synthesize</code> (<code>text</code>, <code>voice</code>, <code>speed</code>). Times are in seconds from the start of the utterance and are deterministic for a given (text, voice, speed), so they line up with the audio from <code>/synthesize</code> requested with the same parameters.</p>
      <pre>curl -X POST https://tts.chriswa.com/timestamps \
  -H "Content-Type: application/json" \
  -d '{"text": "Hello there.", "voice": "af_heart", "speed": 1.2}'</pre>
      <pre>{
  "model": "kokoro-82m", "voice": "af_heart", "speed": 1.2,
  "sample_rate": 24000, "duration": 0.9,
  "words": [
    {"word": "Hello", "start": 0.225, "end": 0.5},
    {"word": "there", "start": 0.5, "end": 0.825}
  ]
}</pre>
    </div>

    <div class="endpoint">
      <h3><span class="method">GET</span>/voices</h3>
      <p>Lists every available voice. The <code>id</code> field of each entry (shown in the dropdown above, before the em-dash) is exactly the string to pass as <code>voice</code> in <code>/synthesize</code>. Block-listed voices are omitted.</p>
      <pre>curl https://tts.chriswa.com/voices</pre>
      <pre>{
  "voices": [
    {"id": "af_heart", "lang_code": "a", "language": "American English", "gender": "female", "label": "Heart (female)"},
    ...
  ],
  "model": "kokoro-82m",
  "default": "af_heart"
}</pre>
    </div>
  </div>
</div>
<script>
const $ = (id) => document.getElementById(id);

// ── progressive (real streaming) playback via Web Audio API ───────────────────
// The server streams a WAV header immediately, then real PCM as it's
// generated. Feeding the whole response to an <audio> element only starts
// playback once the full body is assembled; instead we decode each chunk as
// it arrives and schedule it back-to-back on an AudioContext, so playback
// genuinely starts at first-byte time.
let _audioCtx = null;
function getAudioCtx() {
  if (!_audioCtx) _audioCtx = new (window.AudioContext || window.webkitAudioContext)();
  return _audioCtx;
}
function concatBytes(a, b) {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0); out.set(b, a.length);
  return out;
}
// Rebuild a properly-finalized 44-byte PCM WAV header (real data length) for
// the replay <audio> element — the server's streaming header declares a
// placeholder/unknown size, which browsers can't compute a duration from.
function makeWavHeader(dataLength, fmt) {
  const byteRate = fmt.sampleRate * fmt.channels * (fmt.bitsPerSample >> 3);
  const blockAlign = fmt.channels * (fmt.bitsPerSample >> 3);
  const buf = new ArrayBuffer(44);
  const dv = new DataView(buf);
  const writeStr = (off, s) => { for (let i = 0; i < s.length; i++) dv.setUint8(off + i, s.charCodeAt(i)); };
  writeStr(0, 'RIFF'); dv.setUint32(4, 36 + dataLength, true); writeStr(8, 'WAVE');
  writeStr(12, 'fmt '); dv.setUint32(16, 16, true); dv.setUint16(20, 1, true);
  dv.setUint16(22, fmt.channels, true); dv.setUint32(24, fmt.sampleRate, true);
  dv.setUint32(28, byteRate, true); dv.setUint16(32, blockAlign, true);
  dv.setUint16(34, fmt.bitsPerSample, true); writeStr(36, 'data'); dv.setUint32(40, dataLength, true);
  return new Uint8Array(buf);
}

async function loadVoices() {
  const sel = $('voice');
  try {
    const r = await fetch('/voices');
    const d = await r.json();
    const byLang = {};
    for (const v of d.voices) (byLang[v.language] ??= []).push(v);
    sel.innerHTML = '';
    for (const lang of Object.keys(byLang)) {
      const grp = document.createElement('optgroup');
      grp.label = lang;
      for (const v of byLang[lang]) {
        const opt = document.createElement('option');
        opt.value = v.id;
        // Show the actual API key (v.id) up front — this is exactly what you'd
        // send as the "voice" field to POST /synthesize.
        opt.textContent = `${v.id} — ${v.label}`;
        if (v.id === d.default) opt.selected = true;
        grp.appendChild(opt);
      }
      sel.appendChild(grp);
    }
  } catch (e) {
    sel.innerHTML = '<option>Failed to load voices</option>';
  }
}

async function checkEngine() {
  const dot = $('dot'), txt = $('engine-status');
  try {
    const r = await fetch('/health', {signal: AbortSignal.timeout(4000)});
    const d = await r.json();
    if (d.loaded) {
      dot.className = 'dot ok';
      txt.textContent = `Engine ready (${d.vram_mb} MB VRAM)`;
    } else {
      dot.className = 'dot bad';
      txt.textContent = 'Engine not ready';
    }
  } catch {
    dot.className = 'dot bad';
    txt.textContent = 'Engine unreachable';
  }
}

async function speak() {
  const text = $('text').value.trim();
  const voice = $('voice').value;
  const speed = parseFloat($('speed').value) || 1.2;
  const btn = $('btn-play'), syn = $('syn'), chips = $('chips'), audEl = $('audio');
  if (!text) { syn.className = 'synth-status error'; syn.textContent = 'Enter some text first.'; return; }

  btn.disabled = true;
  syn.className = 'synth-status generating';
  syn.textContent = '⏳ Synthesizing…';
  chips.innerHTML = '';
  audEl.classList.remove('visible');

  // Create/resume the AudioContext synchronously (before any await) so
  // browsers that only honor autoplay tied to a user gesture (e.g. Safari)
  // don't silently leave it suspended.
  const audioCtx = getAudioCtx();
  audioCtx.resume();

  const t0 = performance.now();
  let ttfa = null;

  try {
    const resp = await fetch('/synthesize', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({text, voice, speed}),
    });
    if (!resp.ok) {
      const err = await resp.json().catch(() => ({error: 'HTTP ' + resp.status}));
      throw new Error(err.error || 'HTTP ' + resp.status);
    }

    await audioCtx.resume();
    let nextStartTime = audioCtx.currentTime;

    const reader = resp.body.getReader();
    const pcmChunks = [];
    let firstByte = true;
    let headerBuf = new Uint8Array(0);
    let headerDone = false;
    let fmt = {channels: 1, sampleRate: 24000, bitsPerSample: 16};
    let leftover = new Uint8Array(0);

    function schedulePcm(bytes) {
      if (bytes.length === 0) return;
      const int16 = new Int16Array(bytes.buffer, bytes.byteOffset, bytes.length >> 1);
      const float32 = new Float32Array(int16.length);
      for (let i = 0; i < int16.length; i++) float32[i] = int16[i] / 32768;
      const buf = audioCtx.createBuffer(fmt.channels, float32.length, fmt.sampleRate);
      buf.getChannelData(0).set(float32);
      const src = audioCtx.createBufferSource();
      src.buffer = buf;
      src.connect(audioCtx.destination);
      const startAt = Math.max(nextStartTime, audioCtx.currentTime);
      src.start(startAt);
      nextStartTime = startAt + buf.duration;
    }

    while (true) {
      const {done, value} = await reader.read();
      if (done) break;
      let data = value;
      if (!headerDone) {
        headerBuf = concatBytes(headerBuf, data);
        if (headerBuf.length < 44) continue;
        const dv = new DataView(headerBuf.buffer, headerBuf.byteOffset, 44);
        fmt = {
          channels: dv.getUint16(22, true),
          sampleRate: dv.getUint32(24, true),
          bitsPerSample: dv.getUint16(34, true),
        };
        data = headerBuf.subarray(44);
        headerDone = true;
      }
      let bytes = leftover.length ? concatBytes(leftover, data) : data;
      if (bytes.length % 2 !== 0) {
        leftover = bytes.subarray(bytes.length - 1);
        bytes = bytes.subarray(0, bytes.length - 1);
      } else {
        leftover = new Uint8Array(0);
      }
      // TTFA measured from the first byte of REAL AUDIO, not the WAV header
      // (the header is flushed near-instantly and contains no sound).
      if (bytes.length > 0) {
        if (firstByte) {
          ttfa = performance.now() - t0;
          firstByte = false;
          syn.textContent = `⏳ Receiving… (TTFA: ${ttfa.toFixed(0)}ms)`;
        }
        schedulePcm(bytes);
        pcmChunks.push(bytes);
      }
    }

    const totalMs = performance.now() - t0;
    const serverTtfa = resp.headers.get('X-TTFA-MS');
    const serverTotal = resp.headers.get('X-Total-MS');
    const rtf = resp.headers.get('X-RTF');
    const durSecs = resp.headers.get('X-Audio-Duration');

    const totalPcmLen = pcmChunks.reduce((n, c) => n + c.length, 0);
    const blob = new Blob([makeWavHeader(totalPcmLen, fmt), ...pcmChunks], {type: 'audio/wav'});
    audEl.src = URL.createObjectURL(blob);
    audEl.classList.add('visible');

    syn.className = 'synth-status done';
    syn.textContent = audioCtx.state === 'running'
      ? '✅ Done'
      : '⚠️ Generated, but audio is muted (browser blocked autoplay) — click Speak again';

    const chipList = [];
    if (ttfa != null) chipList.push({label: `TTFA ${ttfa.toFixed(0)}ms`, hi: true});
    else if (serverTtfa) chipList.push({label: `TTFA ${serverTtfa}ms`, hi: true});
    if (serverTotal) chipList.push({label: `synth ${serverTotal}ms`});
    chipList.push({label: `round-trip ${totalMs.toFixed(0)}ms`});
    if (rtf) chipList.push({label: `RTF ${parseFloat(rtf).toFixed(2)}×`});
    if (durSecs) chipList.push({label: `${parseFloat(durSecs).toFixed(1)}s audio`});
    chips.innerHTML = chipList.map(c => `<span class="chip${c.hi ? ' hi' : ''}">${c.label}</span>`).join('');
  } catch (e) {
    syn.className = 'synth-status error';
    syn.textContent = '❌ ' + e.message;
  } finally {
    btn.disabled = false;
  }
}

async function blockVoice() {
  const sel = $('voice');
  const opt = sel.options[sel.selectedIndex];
  if (!opt || !opt.value) return;
  const voice = opt.value;
  const label = opt.textContent;
  if (!confirm(`Block voice "${label}"?\n\nThis removes it from the dropdown (here and via /voices) from now on. There's no undo button in the UI.`)) {
    return;
  }
  const btn = $('btn-block');
  btn.disabled = true;
  try {
    const r = await fetch('/voices/block', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({voice}),
    });
    if (!r.ok) {
      const err = await r.json().catch(() => ({error: 'HTTP ' + r.status}));
      throw new Error(err.error || 'HTTP ' + r.status);
    }
    // Remove it from the dropdown immediately so the UI matches server state
    // without a full reload; clean up the parent optgroup if it's now empty.
    const grp = opt.parentElement;
    opt.remove();
    if (grp && grp.tagName === 'OPTGROUP' && grp.children.length === 0) grp.remove();
    if (sel.options.length === 0) {
      const empty = document.createElement('option');
      empty.textContent = 'No voices left';
      sel.appendChild(empty);
    }
  } catch (e) {
    alert('Failed to block voice: ' + e.message);
  } finally {
    btn.disabled = false;
  }
}

$('btn-play').addEventListener('click', speak);
$('btn-block').addEventListener('click', blockVoice);
loadVoices();
checkEngine();
setInterval(checkEngine, 30000);
</script>
</body>
</html>"""

@app.get("/", response_class=HTMLResponse)
def index():
    return HTML

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "3004")), log_level="warning")
