// swift-tools-version: 6.0
// Voice Operator's client SDK: what a phone (or any client that owns its own
// microphone and speaker) needs to use Voice Operator's hands-free mode, and to
// play the speech Voice Operator makes for it. A package of its
// own, apart from the app's, so it can be a dependency: no unsafeFlags, no
// dependencies. See DESIGN.md, "Hands-free (2026-10-24)" and "Speech on a device".
import PackageDescription

let package = Package(
    name: "VoiceOperatorKit",
    // iOS 17: the engine asks for the microphone through AVAudioApplication.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VoiceOperatorHandsFree", targets: ["VoiceOperatorHandsFree"]),
        .library(name: "VoiceOperatorSpeech", targets: ["VoiceOperatorSpeech"]),
        .library(name: "VoiceOperatorAudio", targets: ["VoiceOperatorAudio"]),
    ],
    targets: [
        // The wire protocol's stream client: Foundation only, transport-agnostic.
        .target(name: "VoiceOperatorHandsFree"),
        // Speech on a device: the speaker client, Foundation only, transport-agnostic.
        .target(name: "VoiceOperatorSpeech"),
        // The iPhone's audio engine (iOS only; empty elsewhere), moved from
        // Spaceterm's NativeMicrophone.swift. Swift 5 mode, as it was written.
        .target(
            name: "VoiceOperatorAudio",
            dependencies: ["VoiceOperatorHandsFree", "VoiceOperatorSpeech"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "VoiceOperatorHandsFreeTests", dependencies: ["VoiceOperatorHandsFree"]),
        .testTarget(name: "VoiceOperatorSpeechTests", dependencies: ["VoiceOperatorSpeech"]),
    ]
)
