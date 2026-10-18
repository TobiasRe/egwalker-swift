import Testing
import Foundation
@testable import EgWalker

/// Randomised testing. Three properties, checked on thousands of random histories:
///
/// 1. **Differential**: the optimized walker produces exactly the same document as
///    the reference oracle, for every replica, at every sync point.
/// 2. **Convergence**: after everyone syncs with everyone, all replicas hold the
///    same text (the defining property of a CRDT).
/// 3. **Invariants**: the B-tree's cached aggregates and LV index stay consistent
///    after every single step (`checkoutValidated`).
///
/// Every case is generated from a seed, so any failure is reproducible with
/// `EGWALKER_FUZZ_SEED=<seed>`. Set `EGWALKER_FUZZ_ITERS` for long soak runs.
@Suite("Fuzzing")
struct FuzzTests {
    static let defaultIterations = 300

    struct Replica {
        var agent: String
        var oplog = OpLog()
        var text: [Unicode.Scalar] = []
        /// A long-lived document, updated only through incremental merges.
        var doc = TextDocument()
    }

    static let alphabet: [Unicode.Scalar] = Array("abcdefghijklmnopqrstuvwxyz ".unicodeScalars)
        + ["ö", "é", "\u{0308}", "€", "😀", "日", "\n"].flatMap { $0.unicodeScalars }

    static func randomText<G: RandomNumberGenerator>(_ rng: inout G) -> String {
        let len = Int.random(in: 1...4, using: &rng)
        var s = String.UnicodeScalarView()
        for _ in 0..<len {
            // Mostly ASCII so the doc stays narrow most of the time; sometimes wide.
            let pool = Int.random(in: 0..<10, using: &rng) < 8 ? 27 : alphabet.count
            s.append(alphabet[Int.random(in: 0..<pool, using: &rng)])
        }
        return String(s)
    }

    /// Runs one random multi-replica editing session.
    static func runCase(seed: UInt64, steps: Int, replicas numReplicas: Int, validateTree: Bool) {
        var rng = SplitMix64(seed: seed)
        // Agent names chosen so byte order differs from creation order sometimes.
        let names = ["mike", "alice", "zed", "bob", "Éva"].shuffled(using: &rng)
        var replicas = (0..<numReplicas).map { Replica(agent: names[$0]) }

        for step in 0..<steps {
            let r = Int.random(in: 0..<numReplicas, using: &rng)
            let action = Int.random(in: 0..<10, using: &rng)
            if action < 7 {
                // Local edit (sometimes several in a row to form runs).
                for _ in 0..<Int.random(in: 1...3, using: &rng) {
                    let len = replicas[r].text.count
                    if len > 0 && Int.random(in: 0..<3, using: &rng) == 0 {
                        let pos = Int.random(in: 0..<len, using: &rng)
                        let n = Int.random(in: 1...Swift.min(3, len - pos), using: &rng)
                        replicas[r].oplog.delete(agent: replicas[r].agent, at: pos, len: n)
                        replicas[r].text.removeSubrange(pos..<(pos + n))
                    } else {
                        let pos = Int.random(in: 0...len, using: &rng)
                        let t = randomText(&rng)
                        replicas[r].oplog.insert(agent: replicas[r].agent, at: pos, t)
                        replicas[r].text.insert(contentsOf: t.unicodeScalars, at: pos)
                    }
                }
            } else {
                // Sync from another replica.
                let from = Int.random(in: 0..<numReplicas, using: &rng)
                if from == r { continue }
                replicas[r].oplog.merge(from: replicas[from].oplog)
                let optimized = validateTree
                    ? replicas[r].oplog.checkoutValidated().text
                    : replicas[r].oplog.checkout().text
                let reference = ReferenceWalker.checkout(replicas[r].oplog).text
                if optimized != reference {
                    Issue.record("seed \(seed) step \(step): optimized != reference\nopt: \(optimized.debugDescription)\nref: \(reference.debugDescription)")
                    return
                }
                // Same history through the depth-first region traversal (normally
                // only used for regions of >= 64 entries).
                let dfs = replicas[r].oplog.checkoutValidated(dfsMinEntries: 2, validate: validateTree).text
                if dfs != reference {
                    Issue.record("seed \(seed) step \(step): depth-first order != reference")
                    return
                }
                replicas[r].text = Array(optimized.unicodeScalars)
                // Incremental merge into the long-lived document must agree.
                replicas[r].doc.merge(replicas[r].oplog)
                if replicas[r].doc.text != reference {
                    Issue.record("seed \(seed) step \(step): incremental merge != reference\ninc: \(replicas[r].doc.text.debugDescription)\nref: \(reference.debugDescription)")
                    return
                }
            }
            // Local text must always agree with a fresh checkout.
            if step % 7 == 0 {
                let co = replicas[r].oplog.checkout().scalars
                if co != replicas[r].text {
                    Issue.record("seed \(seed) step \(step): checkout disagrees with locally maintained text")
                    return
                }
            }
        }

        // Everyone syncs with everyone: must converge.
        var all = OpLog()
        for rep in replicas { all.merge(from: rep.oplog) }
        all.cg.checkInvariants()
        let final = all.checkout().text
        let finalRef = ReferenceWalker.checkout(all).text
        if final != finalRef {
            Issue.record("seed \(seed): final optimized != reference"); return
        }
        if all.checkoutValidated(dfsMinEntries: 2).text != finalRef {
            Issue.record("seed \(seed): final depth-first != reference"); return
        }
        for i in 0..<numReplicas {
            replicas[i].oplog.merge(from: all)
            let t = replicas[i].oplog.checkout().text
            if t != final { Issue.record("seed \(seed): replica \(i) did not converge"); return }
        }
    }

    static var iterations: Int {
        ProcessInfo.processInfo.environment["EGWALKER_FUZZ_ITERS"].flatMap(Int.init) ?? defaultIterations
    }

    @Test func differentialTwoReplicas() {
        if let s = ProcessInfo.processInfo.environment["EGWALKER_FUZZ_SEED"].flatMap(UInt64.init) {
            Self.runCase(seed: s, steps: 60, replicas: 2, validateTree: true); return
        }
        for seed in 0..<UInt64(Self.iterations) {
            Self.runCase(seed: seed, steps: 60, replicas: 2, validateTree: true)
        }
    }

    @Test func differentialManyReplicas() {
        for seed in 0..<UInt64(Self.iterations) {
            Self.runCase(seed: 1_000_000 + seed, steps: 80, replicas: Int(seed % 3) + 3, validateTree: seed % 4 == 0)
        }
    }

    /// Long histories put pressure on B-tree splits (leaf and internal nodes).
    @Test func longHistories() {
        for seed in 0..<UInt64(Swift.max(4, Self.iterations / 30)) {
            Self.runCase(seed: 5_000_000 + seed, steps: 600, replicas: 3, validateTree: seed % 2 == 0)
        }
    }

    /// Incremental merge into an existing branch must equal a full checkout.
    @Test func incrementalMergeMatchesCheckout() {
        for seed in 0..<UInt64(Self.iterations / 2) {
            var rng = SplitMix64(seed: 9_000_000 + seed)
            var a = OpLog(), b = OpLog()
            for _ in 0..<Int.random(in: 1...10, using: &rng) { a.insert(agent: "a", at: 0, Self.randomText(&rng)) }
            b.merge(from: a)
            var branch = ReferenceWalker.checkout(a)
            for _ in 0..<Int.random(in: 1...10, using: &rng) {
                let len = ReferenceWalker.checkout(b).scalars.count
                b.insert(agent: "b", at: Int.random(in: 0...len, using: &rng), Self.randomText(&rng))
                let alen = branch.scalars.count
                a.insert(agent: "a", at: Int.random(in: 0...alen, using: &rng), Self.randomText(&rng))
                branch = ReferenceWalker.checkout(a)
            }
            a.merge(from: b)
            ReferenceWalker.merge(&branch, a)
            #expect(branch.text == a.checkout().text, "seed \(seed)")
        }
    }
}
