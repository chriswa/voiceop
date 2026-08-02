# Compatibility plan — Intel/macOS 13 support + configurable TTS

Status: **approved, not yet implemented.** Written 2026-08-02 from an
investigation session on the Intel machine. Implementation happens on the Apple
Silicon machine (the only one with Xcode).

## Goal

Run Voice Operator on **two** machines with **no feature degradation on either**:

| Machine | Spec | TTS |
|---|---|---|
| Apple Silicon | macOS 15+, Xcode 16, arm64 | local Kokoro (`localhost:56841`) |
| MacBookPro14,3 (2017) | macOS 13.7.8 Ventura, Intel x86_64, **no Xcode** | remote (`https://tts.chriswa.com`) |

The Intel machine never compiles anything — it receives a cross-compiled build
produced on the Apple Silicon machine.

## Why the current tree can't run on Intel/Ventura

Four stacked blockers, found by reproducing `swift build`:

1. **No full Xcode** — `xcode-select -p` → `/Library/Developer/CommandLineTools`.
   SwiftPM calls `xcrun --show-sdk-platform-path`, which only resolves inside a
   full Xcode install. This is the first error you hit.
2. **Swift 6 required** — `swift-tools-version: 6.0`; Ventura's newest Xcode is
   15.2 → Swift 5.9.2.
3. **macOS 15 deployment target** — `platforms: [.macOS(.v15)]`. Ventura is the
   last macOS this 2017 model supports, so this is a hard ceiling.
4. **arm64-only libopus** — `Sources/COpus/lib/libopus.a` is `architecture: arm64`.

Blockers 1 and 2 disappear once all compilation happens on the Apple Silicon
machine. Blockers 3 and 4 are what this plan fixes.

**Nothing in the app's own code needs macOS 14 or 15.** Verified: `SMAppService`
is 13+, `URLSession.bytes` is 12+, and the only `@available(macOS 15.0, *)`
annotations in the tree are in `Sources/FlowAPI/Generated/*.grpc.swift`. The
entire `.v15` floor comes from **grpc-swift 2.x**.

---

## Ground truth: why we keep gRPC (decoded from the Wispr bundle)

Recorded per `CLAUDE.md` so this is never re-investigated. Source:
`/Applications/Wispr Flow.app/Contents/Resources/app.asar` (201 MB, 2026-07-31),
extracted to `/tmp/wispr-app`, symbols in `.webpack/main/index.js`.

**This closes the `OPEN:` question at `spike/flow_request.md:87`** — how the
JSON `/llm/asr_audio_chunks` path surfaces a formatted result.

**It does not.** Decoded from `getFinalTranscriptionResult` (~byte 3979500):

```js
if (isCommandMode || mode === Raw)  return [status, asrText];
if (status === Formatted)           return [status, resp.llm_text || asrText];
if (status === RawTranscript && appType !== AI) {
    let formatted;
    if (!["en","english","engb","english_british","enca","english_canadian"].includes(lang))
        formatted = await AriaWebClient.formatNonEnglish(...);   // NON-ENGLISH ONLY
    return formatted ? [Formatted, formatted] : [RawTranscript, asrText];
}
```

`/llm/asr_audio_chunks` returns `status: "raw_transcript"`. For English that
branch falls through to `[RawTranscript, asrText]` — **raw**. The only follow-up
formatting call is `formatNonEnglish` → `/llm/format_non_english`, gated on the
language *not* being English. Wispr's own app reaches
`transcribeOpenAIAudioChunks` only under a `"Attempting fallback request"` log
line, and leaves English unformatted there.

Status enum values: `Formatted="formatted"`, `RawTranscript="raw_transcript"`,
`Empty="transcription_empty"`, `Fallback="http_fallback"`.

Two endpoints exist that would transcribe-and-format over plain HTTP, but both
are **dead code — one occurrence each, the definition, zero call sites**:

| Symbol | Endpoint | Notes |
|---|---|---|
| `transcribeAndFormat` | `POST /llm/api` | Sends `{audio, properties:{app_type, language, before_text, after_text, selected_text, dictionary}, transcript_id}`; `dictionary` capped at 60, same as `WisprDictionary.maxWords` |
| `formatEnglish` | `POST /llm/formatting` | `{model_name: "openpipe:llama3-1-8b-12-09-2024", content}` |

Do **not** build on these without new bundle evidence. They are unreferenced by
the shipped app, so there is no ground truth that the server still honours them,
and confirming would require exactly the black-box probing `CLAUDE.md` forbids.

**Conclusion:** `status: "formatted"` + `llm_text` only ever arrives from the
Baseten gRPC response. Keeping formatted dictation means keeping gRPC — so the
fix is an older gRPC library, not a different endpoint.

---

## Workstream 1 — Intel / macOS 13 support

**grpc-swift 1.x imposes no macOS 15 floor.** Verified against
`https://raw.githubusercontent.com/grpc/grpc-swift/1.23.0/Package.swift`: it
declares **no `platforms:` block at all**, `swift-tools-version:5.8`, and its
README states platform support tracks SwiftNIO (macOS 10.15+).

Move **both** builds to grpc-swift 1.x → a single code path, no build variants,
no `#if` gating, no conditional dependencies in `Package.swift`.

> **Tradeoff accepted:** grpc-swift 1.x is the older line; 2.x is where
> development continues. We move the Apple Silicon build back one major version
> to keep both machines on one code path, rather than maintaining two generated
> clients and two transcriber implementations indefinitely.

| # | File | Change |
|---|---|---|
| 1 | `Package.swift` | `.macOS(.v15)` → `.macOS(.v13)`; swap grpc-swift 2.x deps for 1.x. **Keep `swift-tools-version: 6.0`** — all builds run on the Apple Silicon machine, so the Intel machine's toolchain is irrelevant |
| 2 | `Sources/FlowAPI/Generated/` | Regenerate with the 1.x `protoc-gen-grpc-swift` |
| 3 | `scripts/gen-proto.sh` | Update plugin invocation/options for 1.x |
| 4 | `Sources/VoiceOperator/Transcriber/WisprFlowTranscriber.swift` | Adapt to the 1.x async API (165 lines; the only file importing GRPC) |
| 5 | `Sources/COpus/lib/libopus.a` | Build an x86_64 slice, `lipo -create` into a universal archive; update `Sources/COpus/README.md` |
| 6 | `Resources/Info.plist` | `LSMinimumSystemVersion` `15.0` → `13.0` |
| 7 | `scripts/make-app.sh` | Cross-compile support — arch + deployment target (`x86_64-apple-macos13.0`) |

The gRPC surface is tiny — only two instantiation sites:
`Core/AudioArbiter.swift:37` (the default `Transcriber`) and
`DebugCLI.swift:51` (`--flow-grpc-test`).

**Distribution:** a `.app` downloaded from a GitHub release is quarantined.
Ad-hoc signed it won't open without `xattr -dr com.apple.quarantine "Voice
Operator.app"`. Document this or notarize.

---

## Workstream 2 — Configurable TTS endpoint

Self-contained and useful on both machines immediately; independent of
Workstream 1.

`$VOICEOP_KOKORO_URL` already exists (`KokoroSynthesizer.swift:32,51`) but a GUI
app launched via `open` **does not inherit the shell environment** — the same
trap already documented in `WisprBasetenKey.swift`. Hence a config file.

New: `~/Library/Application Support/VoiceOperator/config.json`

```json
{
  "tts": {
    "url": "https://tts.chriswa.com",
    "headers": {
      "CF-Access-Client-Id": "…",
      "CF-Access-Client-Secret": "…"
    }
  }
}
```

Precedence: `$VOICEOP_KOKORO_URL` → `config.json` → `http://localhost:56841`.
Both machines run the same binary; only this file differs.

| # | File | Change |
|---|---|---|
| 8 | new `Sources/VoiceOperator/Core/Config.swift` | Load + cache `config.json`; JSON so it can absorb `baseten-key` and future settings rather than accreting one flat file per setting |
| 9 | `Speaker/KokoroSynthesizer.swift` | Apply `tts.url` + `tts.headers` to **both** `/synthesize` and `/voices` |
| 10 | `Speaker/KokoroSynthesizer.swift` | **`Content-Type` guard** — reject non-audio responses |

### The server is already compatible

`tts.chriswa.com` fronts the same `kokoro_server.py` from
`~/acp-host-projects/tts`. Every contract matches:

| Contract | `KokoroSynthesizer` expects | `kokoro_server.py` |
|---|---|---|
| `POST /synthesize` | `{text, voice, speed}` | `body.get("text"/"voice"/"speed")` |
| Sample rate | 24000 | `SAMPLE_RATE = 24000` |
| Sample format | s16le mono | `(audio * 32767).astype(np.int16)` |
| WAV header | 44 bytes, `0xffffffff` placeholders | `_wav_stream_header` packs `0xFFFFFFFF` |
| `GET /voices` | `{voices: [{id: …}]}` | `{"voices": active, …}`, items carry `id` |

The server already has WAN egress pacing tuned for the Cloudflare Tunnel hop.

### Item 10 is required, not defensive padding

`curl -sI https://tts.chriswa.com/health` returns:

```
HTTP/2 302
location: https://chriswatwo.cloudflareaccess.com/cdn-cgi/access/login/tts.chriswa.com?…
www-authenticate: Cloudflare-Access
```

with `"service_token_status":false` in the meta JWT. Cloudflare Access is the
authZ boundary (`kokoro_server.py:177`); the server has no auth of its own.

`URLSession` follows redirects by default, so **without the guard** the app
chases that 302 to an HTML login page, gets a `200`, strips 44 bytes as if it
were a WAV header, and plays the remaining HTML as PCM noise.

**Action required:** mint a Cloudflare Access **service token** and put the
`CF-Access-Client-Id` / `CF-Access-Client-Secret` pair in `config.json` on the
Intel machine.

---

## Workstream 3 — Documentation

| # | File | Change |
|---|---|---|
| 11 | `spike/flow_request.md:87` | Replace the `OPEN:` with the finding above |
| 12 | `DESIGN.md` | Record the `getFinalTranscriptionResult` logic and the two dead-code endpoints |
| 13 | `README.md` | **Rewrite** the `Requirements` section — it currently documents the pre-change floor (macOS 15 / arm64 / Xcode 16). After Workstream 1 it should read macOS 13+, universal binary, built on Apple Silicon. Add the Gatekeeper quarantine note |

---

## Suggested order

1. **Workstream 2** — self-contained, no toolchain risk, immediately useful.
2. **Workstream 1** — the real work; item 5 (universal libopus) first, since
   items 1–4 can't be verified without it.
3. **Workstream 3** — after 1 lands, so the README describes reality.

## Unverified — read, not compiled

These need an actual build on the Apple Silicon machine:

- grpc-swift 1.x compiling clean at `.macOS(.v13)` under Swift 6
- Cross-compiling x86_64 from Apple Silicon (standard, but untried here)
- Building libopus for x86_64 and `lipo`-ing it universal
- Whether the 1.x generated client's API shape needs more than mechanical
  changes in `WisprFlowTranscriber`

## Resolved

- **Wispr Flow is co-installed on all machines**, so `WisprToken` can read the
  JWT from `session.json` on both. (Had this been false it would have sunk
  Workstream 1 regardless of the gRPC work.)
