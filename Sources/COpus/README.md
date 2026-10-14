# COpus — vendored libopus (Opus encoder)

Prebuilt **universal** (`arm64` + `x86_64`) static `libopus` + its public headers,
wrapped as a SwiftPM `systemLibrary` target so `OpusEncoder` can produce the
20 ms / 320-sample Opus packets Wispr's flow-request paths expect (see
`proto/flow_api_v1.proto`, DESIGN.md Milestone C, and the project `CLAUDE.md`).

- `include/` — opus public headers (from opus 1.5.2)
- `lib/libopus.a` — prebuilt universal static archive (`arm64` + `x86_64`)
- `COPYING` — libopus's BSD-3-Clause license + patent notice, verbatim from the
  1.5.2 tarball. The binary license requires it to ship with the app, so
  `make-app.sh` / `make-release.sh` copy it to
  `Contents/Resources/libopus-COPYING.txt`. Replace it when you upgrade opus.
- `module.modulemap` + `shim.h` — expose `opus.h` to Swift as `import COpus`
- Linked via `-LSources/COpus/lib -lopus` in `Package.swift`.

## Rebuild `lib/libopus.a` (universal)

```bash
curl -LO https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz
tar xzf opus-1.5.2.tar.gz && cd opus-1.5.2

# arm64
./configure --disable-doc --disable-extra-programs --enable-static \
  --prefix=/tmp/opus-arm64 --host=aarch64-apple-darwin \
  CC="clang -arch arm64" \
  CFLAGS="-arch arm64" \
  LDFLAGS="-arch arm64"
make -j"$(sysctl -n hw.ncpu)" && make install && make distclean

# x86_64
./configure --disable-doc --disable-extra-programs --enable-static \
  --prefix=/tmp/opus-x86_64 --host=x86_64-apple-darwin \
  CC="clang -arch x86_64" \
  CFLAGS="-arch x86_64" \
  LDFLAGS="-arch x86_64"
make -j"$(sysctl -n hw.ncpu)" && make install

lipo -create /tmp/opus-arm64/lib/libopus.a /tmp/opus-x86_64/lib/libopus.a \
  -output <repo>/Sources/COpus/lib/libopus.a
cp /tmp/opus-arm64/include/opus/*.h <repo>/Sources/COpus/include/
lipo -info <repo>/Sources/COpus/lib/libopus.a   # expect: x86_64 arm64
```
