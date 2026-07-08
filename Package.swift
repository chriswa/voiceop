// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceOperator",
    platforms: [.macOS(.v15)],
    targets: [
        // Vendored libopus (prebuilt arm64 static lib + public headers) for Opus
        // encoding on the Wispr flow-request paths. See Sources/COpus/README.
        .systemLibrary(name: "COpus", path: "Sources/COpus"),
        .executableTarget(
            name: "VoiceOperator",
            dependencies: ["COpus"],
            path: "Sources/VoiceOperator",
            linkerSettings: [
                .unsafeFlags(["-LSources/COpus/lib", "-lopus"]),
            ]
        ),
        .testTarget(
            name: "VoiceOperatorTests",
            dependencies: ["VoiceOperator"],
            path: "Tests/VoiceOperatorTests"
        ),
    ]
)
