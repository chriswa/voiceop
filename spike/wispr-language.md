# Wispr selected-language finding — 2026-07-27

Source: extracted current Wispr Flow Electron main bundle,
`.webpack/main/index.js`, `transcribeOpenAIAudio`.

The implementation chooses the one configured user language when exactly one is
selected:

```js
let language = prevDetectedLanguage() || "";
if (prefs.user.selectedLanguages?.length === 1) {
  language = prefs.user.selectedLanguages[0];
}
POST /llm/asr { audio, language, prompt: "" }
```

The Flow request serializer also contains
`language: prefs.user.selectedLanguages ?? []`. Our old gRPC proto only has
`LANGUAGE_UNSPECIFIED = 0`; its language enum values are not decoded, so setting
an arbitrary protobuf value would be guessing. Voice Operator therefore routes
explicit English (`"en"`) to the confirmed raw `/llm/asr` request until the
current formatted request is ported.
