import AppKit

// Service mode and `--home` first: every path below may move (see ServiceMode).
if let problem = ServiceMode.configure(CommandLine.arguments) {
    FileHandle.standardError.write(Data("VoiceOperator: \(problem)\n".utf8))
    exit(2)
}

// Transcribe an existing WAV (e.g. a stored dictation clip from
// ~/Library/Application Support/VoiceOperator/stt-history) through Parakeet
// and print the transcript.
if let i = CommandLine.arguments.firstIndex(of: "--transcribe-file"),
   let path = CommandLine.arguments.dropFirst(i + 1).first {
    await DebugCLI.runTranscribeFile(path: path)
    exit(0)
}
// Hands-free end to end against the running app, as a phone would stream it:
// `--hands-free-test [text]` (see HandsFreeTestClient).
if let i = CommandLine.arguments.firstIndex(of: "--hands-free-test") {
    exit(await HandsFreeTestClient.run(text: CommandLine.arguments.dropFirst(i + 1).first
                                       ?? "what is Kevin working on?"))
}
// Dictate `say`-synthesized speech through Parakeet's live path, the way a
// held key does: `--provider-test [text]`.
if let i = CommandLine.arguments.firstIndex(of: "--provider-test") {
    await DebugCLI.runProviderTest(text: CommandLine.arguments.dropFirst(i + 1).first
                                   ?? "Claude and kubectl and Coda are proper nouns.")
    exit(0)
}
// The same through Parakeet and the on-device clean-up pass, setting up the
// clean-up server first (the model must already be downloaded; see README):
// `--cleanup-test [text]`.
if let i = CommandLine.arguments.firstIndex(of: "--cleanup-test") {
    let server = CleanupServer(isBusy: { false })
    server.enable()
    await server.waitForJob()
    let phase = server.phase
    guard phase == .idle else {
        FileHandle.standardError.write(Data("cleanup-test: server not ready: \(phase)\n".utf8))
        exit(1)
    }
    await DebugCLI.runProviderTest(text: CommandLine.arguments.dropFirst(i + 1).first
                                       ?? "um so send the the invoice to Sam by friday no wait thursday", cleanUp: true)
    exit(0)
}
// Manual microphone check for the barge-in capture race: `--duck-race-test
// ordered[:ms]` releases the narration-ducking lease before capture starts (what
// the app does), `racing[:ms]` releases it that many ms afterwards (what it used
// to do). See DebugCLI.runDuckRaceTest.
if let i = CommandLine.arguments.firstIndex(of: "--duck-race-test") {
    let spec = (CommandLine.arguments.dropFirst(i + 1).first ?? "ordered").split(separator: ":")
    await DebugCLI.runDuckRaceTest(ordered: spec.first != "racing",
                                   delayMS: spec.count > 1 ? Int(spec[1]) ?? 0 : 0)
    exit(0)
}
if CommandLine.arguments.contains("--chirp-test") {
    await DebugCLI.runChirpTest()
    exit(0)
}
// Render the menu-bar icon in all four transcript-style states to a PNG contact
// sheet, magnified, over light and dark menu-bar backgrounds.
if CommandLine.arguments.contains("--icon-preview") {
    await DebugCLI.runIconPreview(
        path: CommandLine.arguments.last.flatMap { $0 == "--icon-preview" ? nil : $0 }
            ?? "/tmp/voiceop-icon-preview.png")
    exit(0)
}
if CommandLine.arguments.contains("--summarize-test") {
    await DebugCLI.runSummarizeTest()
    exit(0)
}
// The echo experiment's recording kit (see EchoCapture): `--echo-capture [dir]`,
// `--echo-capture phrases [dir]`, `--echo-replay <capture dir> [phrases dir]`.
if let i = CommandLine.arguments.firstIndex(of: "--echo-capture") {
    var rest = Array(CommandLine.arguments[(i + 1)...])
    let phrases = rest.first == "phrases"
    if phrases { rest.removeFirst() }
    let dir = rest.first.map { URL(fileURLWithPath: $0) }
    if phrases { await EchoCapture.capturePhrases(into: dir) } else { await EchoCapture.capture(into: dir) }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--echo-replay") {
    let rest = Array(CommandLine.arguments[(i + 1)...])
    guard let dir = rest.first else {
        FileHandle.standardError.write(Data("usage: --echo-replay <capture dir> [phrases dir]\n".utf8))
        exit(2)
    }
    await EchoCapture.replay(URL(fileURLWithPath: dir), phrases: rest.dropFirst().first.map { URL(fileURLWithPath: $0) })
    exit(0)
}
if CommandLine.arguments.contains("--tts-test") {
    await DebugCLI.runTTSTest(
        text: CommandLine.arguments.last.flatMap { $0 == "--tts-test" ? nil : $0 }
            ?? "The transcript reader is now running through the voice operator.")
    exit(0)
}

// Headless: the speech engine alone, for another program (DESIGN.md "Service mode").
if ServiceMode.isService {
    let service = ServiceCoordinator()
    service.start()
    ServiceCoordinator.runForever()
}

ApplicationsRelocator.relocateIfNeeded()

// Voice Operator runs as a menu bar accessory: no dock icon, no main window.
// (Equivalent to LSUIElement, set programmatically so no Info.plist is needed
// for `swift run` during development.)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let coordinator = AppCoordinator()
app.delegate = coordinator

app.run()
