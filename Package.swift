// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceOperator",
    platforms: [.macOS(.v15)],
    dependencies: [
        // On-device Parakeet speech recognition (CoreML, Apple Silicon): the
        // Parakeet transcription provider.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
        // ONNX Runtime: hands-free's speech detector (Silero VAD) and end-of-turn
        // model (turn-1-mini).
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", exact: "1.24.2"),
    ],
    targets: [
        // Vendored SpeexDSP echo canceller, for hands-free's experimental echo
        // cancellation on the Mac. See Sources/CSpeexDSP/README.md.
        .target(
            name: "CSpeexDSP",
            path: "Sources/CSpeexDSP",
            exclude: ["COPYING", "README.md"],
            sources: ["src"],
            cSettings: [
                .define("FLOATING_POINT"),
                .define("USE_KISS_FFT"),
                .define("EXPORT", to: ""),
                .unsafeFlags(["-Wno-everything"]),
            ]
        ),

        .executableTarget(
            name: "VoiceOperator",
            dependencies: [
                "CSpeexDSP",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/VoiceOperator"
        ),
        .testTarget(
            name: "VoiceOperatorTests",
            dependencies: ["VoiceOperator"],
            path: "Tests/VoiceOperatorTests"
        ),
    ]
)
