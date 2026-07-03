"""Phase 0 STT spike — prove Wispr's simplest ASR path end to end.

Milestone A: audio -> 16 kHz mono WAV -> base64 -> POST /llm/asr -> transcript.

Reverse-engineered from Wispr's bundle (see DESIGN.md):
    AriaWebClient.transcribeOpenAIAudio:
        body = { audio: base64(WAV), language, prompt: "" }
        POST https://api.wisprflow.ai/llm/asr
        headers: Content-Type: application/json, Authorization: <access_token>

ENDPOINT ETIQUETTE: this makes EXACTLY ONE request per run. No retries, no loops,
no batching. Run it deliberately, not in a poll. Default input is a locally
`say`-generated clip so we don't even need the mic to validate the plumbing.

Usage:
    python3 asr_spike.py                       # speak a default phrase via `say`
    python3 asr_spike.py --say "hello world"   # speak custom text via `say`
    python3 asr_spike.py --record 4            # record 4s from the default mic
    python3 asr_spike.py --dry-run             # build the request, DON'T send it
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

from wispr_token import get_access_token

ASR_URL = "https://api.wisprflow.ai/llm/asr"
SAMPLE_RATE = 16000


def make_wav_via_say(text: str, out_wav: str) -> None:
    """Synthesize speech locally with macOS `say`, then transcode to 16k mono WAV.

    Deterministic and mic-free — ideal for validating the endpoint plumbing.
    """
    aiff = out_wav + ".aiff"
    subprocess.run(["say", "-o", aiff, text], check=True)
    _to_wav(aiff, out_wav)
    os.unlink(aiff)


def record_wav(seconds: int, out_wav: str) -> None:
    """Record `seconds` from the default input device via ffmpeg (avfoundation)."""
    print(f"recording {seconds}s from default mic — speak now...", file=sys.stderr)
    subprocess.run(
        ["ffmpeg", "-y", "-f", "avfoundation", "-i", ":default",
         "-t", str(seconds), "-ar", str(SAMPLE_RATE), "-ac", "1", out_wav],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def _to_wav(src: str, out_wav: str) -> None:
    subprocess.run(
        ["ffmpeg", "-y", "-i", src, "-ar", str(SAMPLE_RATE), "-ac", "1",
         "-c:a", "pcm_s16le", out_wav],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def transcribe(wav_path: str, language: str, dry_run: bool) -> None:
    with open(wav_path, "rb") as f:
        audio_b64 = base64.b64encode(f.read()).decode()
    payload = {"audio": audio_b64, "language": language, "prompt": ""}
    print(f"WAV {os.path.getsize(wav_path)} B -> base64 {len(audio_b64)} chars",
          file=sys.stderr)

    if dry_run:
        print("--dry-run: request built, NOT sent.", file=sys.stderr)
        return

    token = get_access_token()
    req = urllib.request.Request(
        ASR_URL, data=json.dumps(payload).encode(), method="POST",
        headers={"Content-Type": "application/json", "Authorization": token},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            status, body = r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        status, body = e.code, e.read().decode("utf-8", "replace")

    print(f"\nHTTP {status}")
    try:
        print(json.dumps(json.loads(body), indent=2))
    except json.JSONDecodeError:
        print(body[:2000])


def main() -> None:
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--say", metavar="TEXT",
                   help="synthesize this text locally with `say` (mic-free)")
    g.add_argument("--record", type=int, metavar="SECONDS",
                   help="record this many seconds from the default mic")
    ap.add_argument("--language", default="en")
    ap.add_argument("--dry-run", action="store_true",
                    help="build the request but do not send it")
    args = ap.parse_args()

    with tempfile.TemporaryDirectory() as d:
        wav = os.path.join(d, "clip.wav")
        if args.record:
            record_wav(args.record, wav)
        else:
            text = args.say or "Hello, this is a Voice Operator spike test."
            make_wav_via_say(text, wav)
        transcribe(wav, args.language, args.dry_run)


if __name__ == "__main__":
    main()
