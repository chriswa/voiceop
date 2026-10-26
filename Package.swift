// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceOperator",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        // grpc-swift 1.x matches the checked-in generated Flow client. The app
        // targets the current macOS release line; see COMPATIBILITY-PLAN.md.
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.27.0"),
        // Declared explicitly rather than leaned on transitively through
        // grpc-swift: the streaming transcription path names NIO types directly
        // (EventLoopGroup, TimeAmount, HPACKHeaders — see FlowChannel/FlowSession).
        // grpc-swift 1.x already pins a compatible version, so this adds no new
        // resolution, it just makes the imports legitimate.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.31.0"),
        // On-device Parakeet speech recognition (CoreML, Apple Silicon): the
        // Parakeet transcription provider.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
        // ONNX Runtime: hands-free's speech detector (Silero VAD) and end-of-turn
        // model (turn-1-mini).
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", exact: "1.24.2"),
    ],
    targets: [
        // Vendored libopus (prebuilt universal static lib + public headers) for
        // Opus encoding on the Wispr flow-request paths. See Sources/COpus/README.
        .systemLibrary(name: "COpus", path: "Sources/COpus"),

        // Generated Swift for Wispr's flow_api.v1 (messages via swift-protobuf,
        // gRPC client via grpc-swift 1.x) from proto/flow_api_v1.proto.
        // Pre-generated — regenerate via scripts/gen-proto.sh.
        .target(
            name: "FlowAPI",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "GRPC", package: "grpc-swift"),
            ],
            path: "Sources/FlowAPI"
        ),

        .executableTarget(
            name: "VoiceOperator",
            dependencies: [
                "COpus",
                "FlowAPI",
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHPACK", package: "swift-nio-http2"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/VoiceOperator",
            linkerSettings: [
                .unsafeFlags(["-LSources/COpus/lib", "-lopus"]),
            ]
        ),
        .testTarget(
            name: "VoiceOperatorTests",
            dependencies: ["VoiceOperator", "FlowAPI"],
            path: "Tests/VoiceOperatorTests"
        ),
    ]
)
