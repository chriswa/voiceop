# COpus — vendored libopus (Opus encoder)

Prebuilt **arm64** static `libopus` + its public headers, wrapped as a SwiftPM
`systemLibrary` target so `OpusEncoder` can produce the 20 ms / 320-sample Opus
packets Wispr's flow-request paths expect (see `proto/flow_api_v1.proto`,
DESIGN.md Milestone C, and the project `CLAUDE.md`).

- `include/` — opus public headers (from opus 1.5.2)
- `lib/libopus.a` — prebuilt static archive (arm64)
- `module.modulemap` + `shim.h` — expose `opus.h` to Swift as `import COpus`
- Linked via `-LSources/COpus/lib -lopus` in `Package.swift`.

## Rebuild `lib/libopus.a`
```bash
curl -LO https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz
tar xzf opus-1.5.2.tar.gz && cd opus-1.5.2
./configure --disable-doc --disable-extra-programs --enable-static && make -j8
cp .libs/libopus.a  <repo>/Sources/COpus/lib/libopus.a
cp include/*.h      <repo>/Sources/COpus/include/
```
