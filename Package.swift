// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceOperator",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "1.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "1.0.0"),
    ],
    targets: [
        // Vendored libopus (prebuilt arm64 static lib + public headers) for Opus
        // encoding on the Wispr flow-request paths. See Sources/COpus/README.
        .systemLibrary(name: "COpus", path: "Sources/COpus"),

        // Generated Swift for Wispr's flow_api.v1 (messages via swift-protobuf,
        // gRPC client via grpc-swift-protobuf) from Protos/flow_api_v1.proto.
        // Pre-generated (protoc + protoc-gen-swift/grpc-swift) from
        // proto/flow_api_v1.proto — regenerate via scripts/gen-proto.sh.
        .target(
            name: "FlowAPI",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "GRPCCore", package: "grpc-swift"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ],
            path: "Sources/FlowAPI"
        ),

        .executableTarget(
            name: "VoiceOperator",
            dependencies: [
                "COpus",
                "FlowAPI",
                .product(name: "GRPCCore", package: "grpc-swift"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ],
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
