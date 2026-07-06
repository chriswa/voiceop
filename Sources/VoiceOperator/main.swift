import AppKit

// Dev self-test: `swift run VoiceOperator --asr-test [text]` synthesizes speech
// locally with `say`, transcodes to the ASR WAV format, and runs exactly one
// WisprTranscriber call. Mic-free and deterministic — validates the Swift STT
// path without the menu-bar app or microphone permission.
if CommandLine.arguments.contains("--asr-test") {
    await DebugCLI.runASRTest(
        text: CommandLine.arguments.last.flatMap { $0 == "--asr-test" ? nil : $0 }
            ?? "The quick brown fox jumps over the lazy dog.")
    exit(0)
}
// Transcribe an existing WAV (e.g. a stored dictation clip from
// ~/Library/Application Support/VoiceOperator/stt-history) through the real
// chunked WisprTranscriber path and print the transcript.
if let i = CommandLine.arguments.firstIndex(of: "--transcribe-file"),
   let path = CommandLine.arguments.dropFirst(i + 1).first {
    await DebugCLI.runTranscribeFile(path: path)
    exit(0)
}
if CommandLine.arguments.contains("--chirp-test") {
    await DebugCLI.runChirpTest()
    exit(0)
}
if CommandLine.arguments.contains("--summarize-test") {
    await DebugCLI.runSummarizeTest()
    exit(0)
}
if CommandLine.arguments.contains("--tts-test") {
    await DebugCLI.runTTSTest(
        text: CommandLine.arguments.last.flatMap { $0 == "--tts-test" ? nil : $0 }
            ?? "The transcript reader is now running through the voice operator.")
    exit(0)
}

// Voice Operator runs as a menu bar accessory: no dock icon, no main window.
// (Equivalent to LSUIElement, set programmatically so no Info.plist is needed
// for `swift run` during development.)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let coordinator = AppCoordinator()
app.delegate = coordinator

app.run()
