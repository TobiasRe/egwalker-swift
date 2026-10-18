#!/usr/bin/env bash
# Builds the browser demo: the EgWalker library compiled to WebAssembly.
#
# Needs the Swift SDK for Wasm that matches your toolchain, e.g. for 6.4.1:
#   swift sdk install https://download.swift.org/swift-6.4.1-release/wasm-sdk/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE_wasm.artifactbundle.tar.gz
# Optional: wasm-opt (binaryen) on PATH shrinks the binary by about 40%.
#
# Output: web/egwalker.wasm. Serve web/ with any static file server, e.g.
#   python3 -m http.server -d web 8000
set -euo pipefail
cd "$(dirname "$0")"
SDK=${SWIFT_SDK:-$(swift sdk list | grep -E '_wasm$' | head -1)}
swift build --swift-sdk "$SDK" -c release --product EgWalkerWasm \
  -Xswiftc -Xclang-linker -Xswiftc -mexec-model=reactor \
  -Xswiftc -gnone -Xlinker --strip-all
if command -v wasm-opt >/dev/null; then
  wasm-opt -Oz --enable-bulk-memory --enable-sign-ext --enable-mutable-globals \
    --enable-nontrapping-float-to-int .build/release/EgWalkerWasm.wasm -o web/egwalker.wasm
else
  cp .build/release/EgWalkerWasm.wasm web/egwalker.wasm
fi
ls -lh web/egwalker.wasm
