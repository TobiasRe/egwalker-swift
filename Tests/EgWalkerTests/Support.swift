import Foundation
@testable import EgWalker

enum Fixtures {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
    }

    /// Paper traces live outside the test bundle (they are large). Tests that need
    /// them are skipped when the files are missing.
    static func paperTrace(_ name: String) -> URL? {
        let here = URL(fileURLWithPath: #filePath)
        let url = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Benchmarks/data/\(name).json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    nonisolated(unsafe) static var _conformance: [TraceImport.DTExport]?
    static var conformance: [TraceImport.DTExport] {
        if let c = _conformance { return c }
        let c = try! TraceImport.loadDTExports(url("conformance.json"))
        _conformance = c
        return c
    }
}

/// Deterministic PRNG (SplitMix64) so every fuzz failure is reproducible from its seed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
