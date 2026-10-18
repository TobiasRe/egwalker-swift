import Testing
@testable import EgWalker

/// Tests written *because* mutation testing showed a blind spot. Each one names
/// the surviving mutant it kills (see Benchmarks/mutation/TRIAGE.md).
@Suite("Mutation-driven tests")
struct MutationGapTests {
    /// The single-op remote API was never exercised.
    @Test func pushRemoteOpsOneByOne() {
        var a = OpLog()
        a.insert(agent: "a", at: 0, "hi")
        a.delete(agent: "a", at: 0)
        var b = OpLog()
        for lv in 0..<a.count {
            let id = a.cg.lvToRaw(lv)
            let parents = a.cg.parents(of: lv).map { a.cg.lvToRaw($0) }
            let first = b.push(id: id, parents: parents, op: a.op(at: lv))
            let again = b.push(id: id, parents: parents, op: a.op(at: lv))
            #expect(first, "new op must be accepted")
            #expect(!again, "duplicate must be rejected")
        }
        #expect(b.checkout().text == "i")
        #expect(b.latestVersion == a.latestVersion)
    }

    /// Kills `OpLog.swift: fwd || del == 1` -> `&&`: a multi-character forward
    /// delete patch must stay "all at pos", and a backspace patch must count down.
    @Test func importedDeleteDirection() {
        var o = OpLog()
        o.addPatches(agent: "a", seqStart: 0, parents: [], patches: [(0, 0, "abcdefgh", true)])
        o.addPatches(agent: "a", seqStart: 8, parents: [7], patches: [(2, 3, "", true)])
        o.addPatches(agent: "a", seqStart: 11, parents: [10], patches: [(0, 2, "", false)])
        #expect((8..<11).map { o.op(at: $0).pos } == [2, 2, 2])   // Delete key
        #expect((11..<13).map { o.op(at: $0).pos } == [1, 0])     // Backspace
        #expect(o.checkout().text == "fgh")
    }

    /// Kills the RLE mutants in `CausalGraph.add` and `OpLog.pushInsert`: typing
    /// character by character must collapse into one graph entry and one op run.
    /// (Output-only tests can't see this: un-merged runs give the same text.)
    @Test func typingIsRunLengthEncoded() {
        var o = OpLog()
        o.insert(agent: "zz", at: 0, ">")  // so "me"'s entry doesn't start at LV 0
        for (i, c) in "hello world".enumerated() { o.insert(agent: "me", at: i + 1, String(c)) }
        for _ in 0..<5 { o.delete(agent: "me", at: o.checkout().scalars.count - 1) }  // backspace x5
        #expect(o.cg.entryCount == 2)
        #expect(o.runCount == 2)  // one insert run (op runs may span agents), one backspace run
        #expect(o.checkout().text == ">hello ")
    }

    /// Kills `reversed: true` -> `false` in tracked backspace deletes. Needs a
    /// backspace run whose *middle* is the parent of a concurrent branch, so the
    /// walker has to retreat/advance part of the run.
    @Test func backspaceRunPartiallyRetreated() {
        for seed in 0..<UInt64(300) {
            var rng = SplitMix64(seed: 77_000 + seed)
            var a = OpLog(), b = OpLog(), c = OpLog()
            a.insert(agent: "a", at: 0, "0123456789abcdef")
            b.merge(from: a); c.merge(from: a)
            // b edits concurrently with everything below, so a's backspace run is
            // not critical and goes through the tracker.
            b.insert(agent: "b", at: Int.random(in: 0...16, using: &rng), "Q")
            // a backspaces k1 chars, syncs to c mid-run, then keeps backspacing:
            // one op run whose middle is c's parent.
            var pos = Int.random(in: 8...16, using: &rng)
            for _ in 0..<Int.random(in: 1...3, using: &rng) { pos -= 1; a.delete(agent: "a", at: pos) }
            c.merge(from: a)
            for _ in 0..<Int.random(in: 2...4, using: &rng) { pos -= 1; a.delete(agent: "a", at: pos) }
            // c edits right where the backspacing happens.
            let cLen = c.checkout().scalars.count
            let cp = (pos + Int.random(in: -1...3, using: &rng)).clamped(to: 0...cLen)
            c.insert(agent: "c", at: cp, "X")
            if cp > 0 && Int.random(in: 0..<2, using: &rng) == 0 { c.delete(agent: "c", at: cp - 1) }
            a.merge(from: b); a.merge(from: c)
            let ref = ReferenceWalker.checkout(a).text
            #expect(a.checkout().text == ref, "seed \(seed)")
            #expect(a.checkoutValidated(dfsMinEntries: 2).text == ref, "seed \(seed) dfs")
            c.merge(from: a)
            #expect(c.checkout().text == ref, "seed \(seed) convergence")
        }
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { Swift.min(Swift.max(self, r.lowerBound), r.upperBound) }
}
