"""Phase 0 Milestone C spike — Wispr's flow request end to end.

    audio -> 16 kHz mono s16le -> opus (20 ms / 320-sample frames)
          -> flow request -> POST /llm/asr_audio_chunks -> transcript

The request shape is GROUND TRUTH from the Wispr Flow Electron app's
`serializeFlowRequest` (see spike/flow_request.md and the project CLAUDE.md) —
NOT guessed from the endpoint. Validated 200 on 2026-07-08.

ENDPOINT ETIQUETTE: EXACTLY ONE request per run. No retries, no loops.

Requires a libopus shared library for opus encoding via ctypes. Build one:
    curl -LO https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz
    tar xzf opus-1.5.2.tar.gz && cd opus-1.5.2
    ./configure --disable-doc --disable-extra-programs --enable-static && make -j8
    clang -dynamiclib -o /tmp/libopus.dylib -Wl,-all_load .libs/libopus.a -lm
Then point LIBOPUS_DYLIB at it (defaults to /tmp/libopus.dylib).

Usage:
    python3 flow_spike.py --say "Claude and kubectl and Coda"      # mic-free (via `say`)
    python3 flow_spike.py --record 4
    python3 flow_spike.py --say "..." --dry-run                    # build, don't send
"""

import argparse, base64, ctypes, json, os, subprocess, sys, struct, math, tempfile
import urllib.error, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wispr_token import get_access_token

URL = "https://api.wisprflow.ai/llm/asr_audio_chunks"
SAMPLE_RATE = 16000
FRAME = 320                 # 20 ms @ 16 kHz
LIBOPUS = os.environ.get("LIBOPUS_DYLIB", "/tmp/libopus.dylib")
OPUS_APPLICATION_VOIP = 2048

OPUS = ctypes.CDLL(LIBOPUS)
OPUS.opus_encoder_create.restype = ctypes.c_void_p
OPUS.opus_encoder_create.argtypes = [ctypes.c_int32, ctypes.c_int, ctypes.c_int,
                                      ctypes.POINTER(ctypes.c_int)]
OPUS.opus_encode.restype = ctypes.c_int32
OPUS.opus_encode.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int16),
                             ctypes.c_int, ctypes.POINTER(ctypes.c_ubyte), ctypes.c_int32]


def wav_to_pcm(path: str) -> bytes:
    import wave
    with wave.open(path, "rb") as w:
        assert w.getframerate() == SAMPLE_RATE and w.getnchannels() == 1 \
            and w.getsampwidth() == 2, "expected 16 kHz mono s16le WAV"
        return w.readframes(w.getnframes())


def encode_opus(pcm: bytes):
    """s16le PCM -> (packets, volumes): one raw opus packet + one RMS volume per
    20 ms frame (last frame padded with silence)."""
    err = ctypes.c_int()
    enc = OPUS.opus_encoder_create(SAMPLE_RATE, 1, OPUS_APPLICATION_VOIP, ctypes.byref(err))
    if err.value != 0 or not enc:
        raise RuntimeError(f"opus_encoder_create failed: {err.value}")
    fb, packets, volumes = FRAME * 2, [], []
    out = (ctypes.c_ubyte * 4000)()
    for i in range(0, len(pcm), fb):
        chunk = pcm[i:i + fb].ljust(fb, b"\x00")
        pcm_buf = (ctypes.c_int16 * FRAME).from_buffer_copy(chunk)
        n = OPUS.opus_encode(enc, pcm_buf, FRAME, out, 4000)
        if n < 0:
            raise RuntimeError(f"opus_encode failed: {n}")
        packets.append(bytes(out[:n]))
        s = struct.unpack(f"<{FRAME}h", chunk)
        volumes.append(math.sqrt(sum(x * x for x in s) / FRAME) / 32768.0)
    return packets, volumes


def build_request(token: str, packets, volumes, words) -> dict:
    """EXACT shape from serializeFlowRequest (see spike/flow_request.md)."""
    return {
        "access_token": token,
        "audio": None,
        "audio_packets": {
            "packets": [base64.a85encode(p).decode("ascii") for p in packets],
            "volumes": volumes,
            "packet_duration": 0.02,          # seconds (20 ms / 1000)
            "audio_encoding": "opus",
            "byte_encoding": "ascii85",
        },
        "pipeline": ["transcribe", "align", "format"],
        "context": {
            "app": {"name": "Terminal", "bundle_id": "com.apple.Terminal",
                    "type": "other", "url": ""},
            "ax_context": [], "ocr_context": [],
            "dictionary_context": words[:60],
            "user_first_name": "", "user_last_name": "",
            "textbox_contents": None, "content_text": "",
        },
        "personalization_style_settings": None,
        "language": ["en"],
        "app": "other",
        "user": {"uuid": "00000000-0000-0000-0000-000000000000"},
        "metadata": {
            "session_id": "voiceop-spike", "environment": "production",
            "client_platform": "mac", "client_version": "0.0.0",
            "transcript_entity_uuid": "00000000-0000-0000-0000-000000000000",
        },
        "prev_asr_text": "", "prev_llm_text": "", "prev_detected_language": None,
        "last_nonempty_status": None, "debug_mode": False, "test_mode": False,
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--say", metavar="TEXT")
    g.add_argument("--record", type=int, metavar="SECONDS")
    ap.add_argument("--words", default="Claude,kubectl,Coda")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    with tempfile.TemporaryDirectory() as d:
        wav = os.path.join(d, "clip.wav")
        if args.record:
            print(f"recording {args.record}s — speak now...", file=sys.stderr)
            subprocess.run(["ffmpeg", "-y", "-f", "avfoundation", "-i", ":default",
                            "-t", str(args.record), "-ar", str(SAMPLE_RATE), "-ac", "1",
                            "-c:a", "pcm_s16le", wav], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            text = args.say or "Claude and kubectl and Coda are proper nouns."
            aiff = wav + ".aiff"
            subprocess.run(["say", "-o", aiff, text], check=True)
            subprocess.run(["ffmpeg", "-y", "-i", aiff, "-ar", str(SAMPLE_RATE),
                            "-ac", "1", "-c:a", "pcm_s16le", wav], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        pcm = wav_to_pcm(wav)
        packets, volumes = encode_opus(pcm)
        words = [w.strip() for w in args.words.split(",") if w.strip()]
        print(f"{len(pcm)//2} samples ({len(pcm)/2/SAMPLE_RATE:.2f}s) -> "
              f"{len(packets)} opus packets", file=sys.stderr)

        if args.dry_run:
            print("--dry-run: request built, NOT sent.", file=sys.stderr)
            return

        token = get_access_token()
        body = build_request(token, packets, volumes, words)
        req = urllib.request.Request(
            URL, data=json.dumps(body).encode(), method="POST",
            headers={"Content-Type": "application/json", "Authorization": token})
        try:
            with urllib.request.urlopen(req, timeout=25) as r:
                status, resp = r.status, r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            status, resp = e.code, e.read().decode("utf-8", "replace")
        print(f"\nHTTP {status}")
        try:
            print(json.dumps(json.loads(resp), indent=2))
        except json.JSONDecodeError:
            print(resp[:3000])


if __name__ == "__main__":
    main()
