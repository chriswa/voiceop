#!/usr/bin/env python3
"""
Streaming-jitter probe for kokoro_server.py's /synthesize endpoint.

Goal: reproduce and characterize the stuttering the user hears (first ~500ms
of audio, a sub-second silent gap, then the rest) by measuring, per chunk:
  - wall-clock arrival time (relative to the first byte of real audio)
  - how much audio-seconds that chunk represents
  - whether the client would have *needed* that chunk already (i.e. whether
    real-time playback started at t=0 would have starved waiting for it)

This tells us the minimum server-side pre-buffer (in ms) that would absorb
the worst-case generation/network lag for a given (voice, text) pair, so we
can pick a fixed buffering constant for the server instead of asking every
client to do it.

IMPORTANT: runs strictly one request at a time (sequential, with a pause
between requests) — this box has limited VRAM/RAM and running these in
parallel risks OOMing the host, per explicit instruction.
"""
import json
import time
import struct
import statistics
import sys
import urllib.request

HOST = "http://localhost:3004"
SAMPLE_RATE = 24000
BYTES_PER_SAMPLE = 2  # int16 mono

TEXTS = {
    "tiny":   "Hello, my friends,",
    "short":  "The quick brown fox jumps over the lazy dog.",
    "medium": ("The quick brown fox jumps over the lazy dog. "
               "She sells seashells by the seashore, and the shells she sells "
               "are seashells, I'm sure."),
    "long":   (("The quick brown fox jumps over the lazy dog. " * 3) +
               "This is a considerably longer passage intended to measure "
               "sustained streaming throughput once generation has warmed up, "
               "rather than just the very first chunk of audio. " * 3),
}

VOICES = ["af_heart", "am_adam", "bf_emma", "hf_alpha"]

PAUSE_BETWEEN_REQUESTS_SEC = 2.0


def synthesize_and_measure(text: str, voice: str):
    """POSTs to /synthesize, reads the stream in small increments, and records
    (relative_arrival_time, byte_length) for every distinct read() that
    returns new audio bytes. Returns a dict of measurements."""
    body = json.dumps({"text": text, "voice": voice}).encode()
    req = urllib.request.Request(
        f"{HOST}/synthesize", data=body,
        headers={"Content-Type": "application/json"}, method="POST",
    )

    t_request_start = time.perf_counter()
    chunks = []  # list of (t_relative_to_first_audio_byte, n_bytes)
    header_buf = b""
    header_done = False
    t_first_audio_byte = None
    leftover = b""

    with urllib.request.urlopen(req) as resp:
        t_response_open = time.perf_counter()
        while True:
            data = resp.read(4096)  # small read size so we see fine-grained arrival timing
            if not data:
                break
            t_now = time.perf_counter()

            if not header_done:
                header_buf += data
                if len(header_buf) < 44:
                    continue
                data = header_buf[44:]
                header_done = True

            payload = leftover + data
            if len(payload) % 2 != 0:
                leftover = payload[-1:]
                payload = payload[:-1]
            else:
                leftover = b""

            if not payload:
                continue

            if t_first_audio_byte is None:
                t_first_audio_byte = t_now
            chunks.append((t_now - t_first_audio_byte, len(payload)))

    t_end = time.perf_counter()

    if t_first_audio_byte is None:
        return {"error": "no audio bytes received", "voice": voice, "text_len": len(text)}

    ttfa_ms = (t_first_audio_byte - t_request_start) * 1000
    total_ms = (t_end - t_request_start) * 1000

    # Simulate real-time playback starting exactly at t_first_audio_byte (t=0
    # in our relative timeline) — same scheduling model the frontend's
    # AudioContext uses: each chunk must start playing right when the
    # previous one finishes. required_buffer_i is how far *ahead* generation
    # would have needed to already be, at the time chunk i arrived, to avoid
    # a gap. The max over all chunks is the minimum fixed pre-buffer needed.
    cumulative_playback_time = 0.0
    max_required_buffer_sec = 0.0
    per_chunk = []
    total_audio_bytes = 0
    for t_arrival, nbytes in chunks:
        duration = nbytes / BYTES_PER_SAMPLE / SAMPLE_RATE
        required_buffer = t_arrival - cumulative_playback_time
        max_required_buffer_sec = max(max_required_buffer_sec, required_buffer)
        per_chunk.append({
            "t_arrival_ms": round(t_arrival * 1000, 1),
            "bytes": nbytes,
            "duration_ms": round(duration * 1000, 1),
            "playback_deadline_ms": round(cumulative_playback_time * 1000, 1),
            "gap_ms": round(max(0.0, required_buffer) * 1000, 1),
        })
        cumulative_playback_time += duration
        total_audio_bytes += nbytes

    audio_duration_sec = total_audio_bytes / BYTES_PER_SAMPLE / SAMPLE_RATE
    rtf = (total_ms / 1000) / audio_duration_sec if audio_duration_sec > 0 else None

    return {
        "voice": voice,
        "text_len": len(text),
        "n_chunks": len(chunks),
        "ttfa_ms": round(ttfa_ms, 1),
        "total_ms": round(total_ms, 1),
        "audio_duration_ms": round(audio_duration_sec * 1000, 1),
        "rtf": round(rtf, 3) if rtf else None,
        "min_required_prebuffer_ms": round(max_required_buffer_sec * 1000, 1),
        "per_chunk": per_chunk,
    }


def main():
    only_tiny = "--quick" in sys.argv
    results = []
    text_items = [("tiny", TEXTS["tiny"])] if only_tiny else list(TEXTS.items())
    voice_items = VOICES[:2] if only_tiny else VOICES

    for text_name, text in text_items:
        for voice in voice_items:
            print(f"\n=== {text_name} ({len(text)} chars) / voice={voice} ===", flush=True)
            try:
                r = synthesize_and_measure(text, voice)
            except Exception as e:
                print(f"  ERROR: {e}")
                time.sleep(PAUSE_BETWEEN_REQUESTS_SEC)
                continue

            if "error" in r:
                print(f"  ERROR: {r['error']}")
            else:
                print(f"  TTFA={r['ttfa_ms']}ms  total={r['total_ms']}ms  "
                      f"audio={r['audio_duration_ms']}ms  RTF={r['rtf']}  "
                      f"chunks={r['n_chunks']}  "
                      f"MIN_REQUIRED_PREBUFFER={r['min_required_prebuffer_ms']}ms")
                # Show the chunk(s) that drove the worst-case buffer requirement
                worst = sorted(r["per_chunk"], key=lambda c: c["gap_ms"], reverse=True)[:3]
                for c in worst:
                    if c["gap_ms"] > 0:
                        print(f"    stall risk: chunk arrived at {c['t_arrival_ms']}ms "
                              f"but playback needed it by {c['playback_deadline_ms']}ms "
                              f"(would starve for {c['gap_ms']}ms) — chunk duration {c['duration_ms']}ms, {c['bytes']} bytes")
                results.append({**r, "text_name": text_name})

            time.sleep(PAUSE_BETWEEN_REQUESTS_SEC)

    if results:
        print("\n\n=== SUMMARY ===")
        print(f"{'text':<8} {'voice':<10} {'chunks':>7} {'ttfa_ms':>9} {'rtf':>6} {'prebuffer_ms':>13}")
        for r in results:
            print(f"{r['text_name']:<8} {r['voice']:<10} {r['n_chunks']:>7} "
                  f"{r['ttfa_ms']:>9} {r['rtf']:>6} {r['min_required_prebuffer_ms']:>13}")
        worst_overall = max(results, key=lambda r: r["min_required_prebuffer_ms"])
        print(f"\nWorst-case required prebuffer across all tests: "
              f"{worst_overall['min_required_prebuffer_ms']}ms "
              f"({worst_overall['text_name']}/{worst_overall['voice']})")
        recommended = max(r["min_required_prebuffer_ms"] for r in results)
        print(f"Recommended fixed server-side prebuffer (with ~50ms safety margin): "
              f"{round(recommended + 50)}ms")


if __name__ == "__main__":
    main()
