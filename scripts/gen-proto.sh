#!/usr/bin/env bash
# Regenerate Sources/FlowAPI/Generated from proto/flow_api_v1.proto.
# Needs `protoc` (brew install protobuf). Builds the Swift plugins from the
# resolved SwiftPM deps, then runs protoc.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product protoc-gen-swift --product protoc-gen-grpc-swift
BIN=.build/debug
rm -f Sources/FlowAPI/Generated/*.swift
protoc --proto_path=proto \
  --plugin=protoc-gen-swift="$BIN/protoc-gen-swift" \
  --plugin=protoc-gen-grpc-swift="$BIN/protoc-gen-grpc-swift" \
  --swift_out=Sources/FlowAPI/Generated --swift_opt=Visibility=Public \
  --grpc-swift_out=Sources/FlowAPI/Generated \
  --grpc-swift_opt=Visibility=Public,Client=true,Server=false \
  proto/flow_api_v1.proto
echo "generated Sources/FlowAPI/Generated/"
