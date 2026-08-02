# Wispr flow request — `POST /llm/asr_audio_chunks` (Milestone C)

Ground truth, reverse-engineered from the Wispr Flow Electron app
(`/Applications/Wispr Flow.app/Contents/Resources/app.asar`, `.webpack/main/index.js`,
`serializeFlowRequest`), **validated with one live 200 on 2026-07-08**. This is the
purpose-built dictionary-biasing path — the correct place for custom words, unlike
the `/llm/asr` `prompt` (which is raw-Whisper context and mis-biases; see
`WisprTranscriber`).

> Do NOT reverse-engineer this by probing the live endpoint. Read the app bundle
> (see the project `CLAUDE.md`). The server accepts a base64 string where it wants
> ascii85 and just decodes garbage — black-box probing silently gets this wrong.

## Endpoint

    POST https://api.wisprflow.ai/llm/asr_audio_chunks
    Authorization: <raw access token>        (NOT "Bearer …")
    Content-Type: application/json
    (client-side per-request timeout ~20 s, matching /llm/asr)

`AriaWebClient.transcribeOpenAIAudioChunks(body)` posts the whole flow object.
There is also a msgpack/binary variant (feature-flagged `UseMsgPack`) and a
gRPC/WebSocket streaming path; **we replicate the JSON HTTP path.**

## Body (JSON path)

```jsonc
{
  "access_token": "<jwt>",
  "audio": null,                     // base64(WAV) OR null when sending packets
  "audio_packets": {
    "packets": ["<ascii85(opusFrame)>", ...],  // one per 20 ms frame
    "volumes": [0.0, ...],           // one float per packet (PCM RMS, sample/32768)
    "packet_duration": 0.02,         // SECONDS  (app: packetDuration_ms / 1000)
    "audio_encoding": "opus",
    "byte_encoding": "ascii85"       // JSON path. (binary/msgpack path uses "binary")
  },
  "pipeline": ["transcribe", "align", "format"],   // enum values; see pipelineSteps()
  "context": {
    "app": { "name": "<str>", "bundle_id": "<str>", "type": "<AppType>", "url": "<str>" },
    "ax_context": ["<word>", ...],   // accessibility-parsed words (list; [] ok)
    "ocr_context": ["<word>", ...],  // screen-OCR words (list; [] ok)
    "dictionary_context": ["Claude", "kubectl", ...],  // custom words, strings, capped 60
    "user_first_name": "<str>",
    "user_last_name": "<str>",
    "textbox_contents": null,        // object OR null (limitedTextboxContents() → null common)
    "content_text": "<str>"          // string ("" ok)
  },
  "personalization_style_settings": null,
  "language": ["en"],                // LIST (selectedLanguages), not a bare string
  "app": "<AppType>",                // top-level app type string (e.g. "other")
  "user": { "uuid": "<uuid>" },
  "metadata": {
    "session_id": "<str>", "environment": "<str>", "client_platform": "<str>",
    "client_version": "<str>", "transcript_entity_uuid": "<uuid>"
  },
  "prev_asr_text": "", "prev_llm_text": "", "prev_detected_language": null,
  "last_nonempty_status": null, "debug_mode": false, "test_mode": false
}
```

### Encoding details (from the bundle)
- **Opus**: 16 kHz mono, 20 ms / **320-sample** frames, `OPUS_APPLICATION_VOIP`;
  the last partial frame is padded with silence. Matches Wispr's WS/opus worker.
- **ascii85**: `require('ascii85').encode(buf)` — standard Ascii85, charset chars
  33–117, **no `<~ ~>` delimiters** (option defaults false), no group-space. Python's
  `base64.a85encode` reproduces it exactly (the `z` zero-group shortcut never fires on
  high-entropy Opus data).
- **`AppType`** enum values include `email`, `ai`, `terminal`, `document`, `other`.
  `"unknown"` is rejected; `"other"` is a safe default.
- **`pipeline`** stage enum: `transcribe`, `align`, `format`, `lowercase_sentences`.
  `pipelineSteps(true)` → `["transcribe","align"]` + `format` unless Raw mode.

## Validated response (200)

```jsonc
{ "status": "raw_transcript",
  "asr_text": "Claude and cubectyl and coda are proper nouns.",
  "detected_language": "en", "asr_time": 615, "total_time": 615,
  "llm_time": null, "llm_text": null, "pipeline_time": null, "pipeline_text": null,
  "cursor_position": null, "average_log_prob": null, "starts_with_proper_noun": null }
```

Note `status: "raw_transcript"` with `llm_text: null`: this call returned only the
first pipeline stage. "Claude" already spells correctly here via `dictionary_context`
(the win).

**Resolved (2026-08-02, from Wispr bundle `getFinalTranscriptionResult`):** the JSON
`/llm/asr_audio_chunks` path does **not** surface a formatted English result.
For English it returns `[RawTranscript, asrText]`. The only follow-up formatting
call is `formatNonEnglish` → `/llm/format_non_english`, gated on the language *not*
being English. Status enum: `Formatted="formatted"`, `RawTranscript="raw_transcript"`,
`Empty="transcription_empty"`, `Fallback="http_fallback"`.

Two HTTP endpoints that would transcribe-and-format exist as **dead code** (one
definition each, zero call sites) — do not build on them without new bundle evidence:

| Symbol | Endpoint |
|---|---|
| `transcribeAndFormat` | `POST /llm/api` |
| `formatEnglish` | `POST /llm/formatting` |

`status: "formatted"` + `llm_text` only arrives from the Baseten gRPC response.
See `COMPATIBILITY-PLAN.md` ("Ground truth: why we keep gRPC") and DESIGN.md
Milestone C.

## Repro

`spike/flow_spike.py` builds exactly this body and posts one request. It needs a
libopus dylib (build: `spike/README` / see the script header). Token is read at
runtime from Wispr's `session.json` via `wispr_token.py` and never stored.
