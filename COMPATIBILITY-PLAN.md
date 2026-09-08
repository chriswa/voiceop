# Compatibility policy

Voice Operator targets the latest macOS release. Older-system compatibility is
not a project requirement: do not lower the deployment target, preserve legacy
workarounds, or select dependencies for an older macOS release.

The app remains universal (`arm64` and `x86_64`) where the current toolchain
supports those architectures. The checked-in `grpc-swift` 1.x Flow client is
kept because it matches the generated source, not to support an older OS.
