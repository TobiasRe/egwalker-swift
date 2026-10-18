// swift-tools-version: 6.0
import PackageDescription

// The browser demo. Builds the real EgWalker library for WebAssembly:
//
//   ./build.sh            # needs the Swift SDK for Wasm matching your toolchain
//
// Kept as a separate package so the library itself stays free of Wasm-specific
// targets and flags.
let package = Package(
    name: "EgWalkerDemo",
    dependencies: [.package(path: "..")],
    targets: [
        // Exports a small C-style API to JavaScript (see web/app.js).
        .executableTarget(
            name: "EgWalkerWasm",
            dependencies: [.product(name: "EgWalker", package: "EgWalker")]
        ),
        // Differential fuzzing and conformance inside the Wasm runtime, run with
        // Node's WASI support (check.mjs). Proves the 32-bit build behaves the same.
        .executableTarget(
            name: "EgWalkerWasmCheck",
            dependencies: [.product(name: "EgWalker", package: "EgWalker")]
        ),
    ]
)
