// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceOperator",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "VoiceOperator",
            path: "Sources/VoiceOperator"
        ),
        .testTarget(
            name: "VoiceOperatorTests",
            dependencies: ["VoiceOperator"],
            path: "Tests/VoiceOperatorTests"
        ),
    ]
)
