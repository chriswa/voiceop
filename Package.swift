// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceOperator",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        // grpc-swift 1.x (not 2.x): 2.x floors the deployment target at macOS 15
        // via @available on generated clients. 1.x tracks SwiftNIO (macOS 10.15+),
        // which lets us ship a universal binary for Intel/Ventura. See
        // COMPATIBILITY-PLAN.md Workstream 1.
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.27.0"),
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
