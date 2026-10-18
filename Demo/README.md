# Browser demo

The real EgWalker library compiled to WebAssembly, running three replicas in the
browser. Type in any replica, take one offline, edit, reconnect, and inspect the
event graph and replay statistics.

```bash
./build.sh                          # web/egwalker.wasm (needs the Swift SDK for Wasm)
python3 -m http.server -d web 8000  # then open http://localhost:8000
node check.mjs 1000                 # conformance + fuzzing inside the wasm32 runtime
```

- `Sources/EgWalkerWasm`: a small C ABI (`eg_insert`, `eg_merge`, `eg_state`, …) that
  JavaScript calls. Each replica is a real `OpLog`; syncing is `merge(from:)`.
- `web/engine.js`: loads the module with a minimal WASI shim and wraps the exports.
- `web/index.html`: the UI. No framework, no build step.
- `Sources/EgWalkerWasmCheck` + `check.mjs`: run the diamond-types conformance suite
  and differential fuzzing against the reference walker *inside* WebAssembly, under
  Node's WASI. This is how the 32-bit build is verified (see below).

## Notes on the WebAssembly build

- **32-bit `Int`.** wasm32 has 32-bit `Int`. The placeholder base used to be
  `1 << 60`, which silently becomes 0 on 32-bit, and the build trapped. It is now
  `1 << 30` on 32-bit platforms (unchanged on 64-bit), which limits a document to
  about a billion events, far beyond what a browser tab holds.
- **No Foundation in the core.** The library only needed libc (`malloc`, `realloc`,
  `getenv`), plus Foundation for the JSON trace loaders. The loaders are now left
  out of WASI builds, which shrinks the module from 54 MB to 3.5 MB (1.3 MB gzipped).
- Built with the official Swift SDK for Wasm (Swift 6.4.1) as a WASI reactor, then
  `wasm-opt -Oz`.
