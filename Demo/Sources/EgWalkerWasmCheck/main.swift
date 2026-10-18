// Runs inside the WebAssembly runtime (Node's WASI, see ../check.mjs) to show that
// the 32-bit wasm32 build of EgWalker behaves exactly like the 64-bit native one:
//
// 1. the diamond-types conformance suite (path passed as the first argument);
// 2. differential fuzzing against the reference walker, like Tests/FuzzTests.swift,
//    using only the public API.
import EgWalker
import Foundation

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

let alphabet: [Unicode.Scalar] = Array("abcdefghijklmnopqrstuvwxyz ".unicodeScalars)
    + ["ö", "é", "\u{0308}", "€", "😀", "日", "\n"].flatMap { $0.unicodeScalars }

func randomText<G: RandomNumberGenerator>(_ rng: inout G) -> String {
    var s = String.UnicodeScalarView()
    for _ in 0..<Int.random(in: 1...4, using: &rng) {
        let pool = Int.random(in: 0..<10, using: &rng) < 8 ? 27 : alphabet.count
        s.append(alphabet[Int.random(in: 0..<pool, using: &rng)])
    }
    return String(s)
}

nonisolated(unsafe) var failures = 0
func fail(_ msg: String) { failures += 1; print("FAIL: \(msg)") }

// 1. Conformance
let args = CommandLine.arguments
if args.count > 1 {
    let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
    let runs = try JSONDecoder().decode([TraceImport.DTExport].self, from: data)
    for (i, run) in runs.enumerated() {
        let oplog = TraceImport.oplog(from: run)
        if oplog.checkout().text != run.endContent { fail("conformance case \(i)") }
        if ReferenceWalker.checkout(oplog).text != run.endContent { fail("conformance case \(i) (reference)") }
    }
    print("conformance: \(runs.count) histories checked")
}

// 2. Differential fuzzing
let iterations = args.count > 2 ? Int(args[2]) ?? 200 : 200
for seed in 0..<UInt64(iterations) {
    var rng = SplitMix64(seed: 1_000_000 + seed)
    let names = ["mike", "alice", "zed", "bob", "Éva"].shuffled(using: &rng)
    let n = Int.random(in: 2...4, using: &rng)
    var logs = (0..<n).map { _ in OpLog() }
    var texts = Array(repeating: [Unicode.Scalar](), count: n)
    let docs = (0..<n).map { _ in TextDocument() }
    for _ in 0..<60 {
        let r = Int.random(in: 0..<n, using: &rng)
        if Int.random(in: 0..<10, using: &rng) < 7 {
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                let len = texts[r].count
                if len > 0 && Int.random(in: 0..<3, using: &rng) == 0 {
                    let pos = Int.random(in: 0..<len, using: &rng)
                    let k = Int.random(in: 1...min(3, len - pos), using: &rng)
                    _ = logs[r].delete(agent: names[r], at: pos, len: k)
                    texts[r].removeSubrange(pos..<(pos + k))
                } else {
                    let pos = Int.random(in: 0...len, using: &rng)
                    let t = randomText(&rng)
                    _ = logs[r].insert(agent: names[r], at: pos, t)
                    texts[r].insert(contentsOf: t.unicodeScalars, at: pos)
                }
            }
        } else {
            let from = Int.random(in: 0..<n, using: &rng)
            if from == r { continue }
            logs[r].merge(from: logs[from])
            let opt = logs[r].checkout().text
            let ref = ReferenceWalker.checkout(logs[r]).text
            if opt != ref { fail("seed \(seed): optimized != reference"); break }
            docs[r].merge(logs[r])
            if docs[r].text != ref { fail("seed \(seed): incremental merge != reference"); break }
            texts[r] = Array(opt.unicodeScalars)
        }
    }
    var all = OpLog()
    for l in logs { all.merge(from: l) }
    if all.checkout().text != ReferenceWalker.checkout(all).text { fail("seed \(seed): final != reference") }
}
print("fuzz: \(iterations) multi-replica sessions checked")
print(failures == 0 ? "ALL OK" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
