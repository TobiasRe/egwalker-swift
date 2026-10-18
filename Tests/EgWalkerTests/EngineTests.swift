import Testing
import Foundation
@testable import EgWalker

@Suite("Optimized walker")
struct EngineTests {
    @Test func simpleLocalEditing() {
        var oplog = OpLog()
        oplog.insert(agent: "seph", at: 0, "hi")
        oplog.insert(agent: "seph", at: 2, " there")
        oplog.delete(agent: "seph", at: 0, len: 1)
        #expect(oplog.checkout().text == "i there")
    }

    /// The example from README.md, verbatim.
    @Test func readmeExample() {
        var alice = OpLog(), bob = OpLog()
        alice.insert(agent: "alice", at: 0, "Hello")
        bob.merge(from: alice)
        alice.insert(agent: "alice", at: 5, " world")
        bob.insert(agent: "bob", at: 0, "Oh, ")
        alice.merge(from: bob)
        bob.merge(from: alice)
        #expect(alice.checkout().text == bob.checkout().text)
        #expect(alice.checkout().text == "Oh, Hello world")
    }

    /// Incremental merge: keep a document open while remote edits arrive.
    @Test func incrementalDocumentMerge() throws {
        let data = try TraceImport.loadDTExport(Fixtures.url("git-makefile-raw.json"))
        let full = TraceImport.oplog(from: data)
        // Replay the history in 10 slices into one long-lived document.
        let doc = TextDocument()
        var heads: [LV] = []
        let step = Swift.max(1, full.count / 10)
        var v = step - 1
        while v < full.count - 1 {
            heads = full.cg.findDominators(heads + [v])
            doc.merge(full, upTo: [v])
            v += step
        }
        doc.merge(full)
        #expect(doc.text == data.endContent)
        #expect(doc.version == full.cg.heads)
    }

    @Test func concurrentInserts() {
        var a = OpLog(), b = OpLog()
        a.insert(agent: "alice", at: 0, "A")
        b.insert(agent: "bob", at: 0, "B")
        a.merge(from: b)
        b.merge(from: a)
        #expect(a.checkout().text == "AB")
        #expect(b.checkout().text == "AB")
    }

    @Test func conformanceSuite() {
        var failures = 0
        for (i, run) in Fixtures.conformance.enumerated() {
            let oplog = TraceImport.oplog(from: run)
            let (text, _) = oplog.checkoutValidated()
            if text != run.endContent {
                failures += 1
                Issue.record("conformance case \(i): got \(text.debugDescription) expected \(run.endContent.debugDescription)")
                if failures > 3 { return }
            }
        }
    }

    @Test(arguments: ["ff-raw.json", "git-makefile-raw.json", "node_nodecc-raw.json"])
    func rawTraces(_ name: String) throws {
        let data = try TraceImport.loadDTExport(Fixtures.url(name))
        let oplog = TraceImport.oplog(from: data)
        #expect(oplog.checkout().text == data.endContent)
    }

    @Test(arguments: ["S1", "S2", "S3", "C1", "C2", "A1", "A2"])
    func paperTraces(_ name: String) throws {
        guard let url = Fixtures.paperTrace(name) else { return }
        let trace = try TraceImport.loadConcurrentTrace(url)
        let oplog = TraceImport.oplog(from: trace)
        let result = oplog.checkoutWithStats()
        let text = Branch(scalars: result.text).text
        #expect(text.unicodeScalars.count == trace.endContent.unicodeScalars.count, "\(name) length")
        // The anonymised trace format replaces agent names with indexes. For A2,
        // concurrent inserts at the same position are tie-broken by agent name, so
        // the original endContent is not reproducible from this format (diamond-types
        // warns about exactly this when exporting). PaperTraceDTTests checks A2 with
        // the original names, byte for byte.
        if name != "A2" { #expect(text == trace.endContent, "\(name) content") }
    }
}

@Suite("Causal graph")
struct CausalGraphTests {
    /// Regression test: Swift String equality uses canonical equivalence, so these
    /// two names compare equal as Strings even though they are different agents.
    @Test func agentNamesAreComparedByBytes() {
        let precomposed = "Geisend\u{00F6}rfer"
        let decomposed = "Geisendo\u{0308}rfer"
        #expect(precomposed == decomposed)  // Swift says equal...
        var cg = CausalGraph()
        cg.add(agent: precomposed, seqStart: 0, seqEnd: 3, parents: [])
        let r = cg.add(agent: decomposed, seqStart: 0, seqEnd: 3, parents: [2])
        #expect(r == LVRange(3, 6))          // ...but they are different agents.
        #expect(cg.nextSeq(forAgent: decomposed) == 3)
    }
}

@Suite("Paper traces with original agent names (exported from .dt)")
struct PaperTraceDTTests {
    @Test(arguments: ["S1", "S2", "S3", "C1", "C2", "A1", "A2"])
    func dtExported(_ name: String) throws {
        guard let url = Fixtures.paperTrace("\(name).dt") else { return }
        let data = try TraceImport.loadDTExport(url)
        let oplog = TraceImport.oplog(from: data)
        oplog.cg.checkInvariants()
        #expect(oplog.checkout().text == data.endContent, "\(name)")
        // Both traversal orders, on every region, must give the same document.
        #expect(oplog.checkoutValidated(dfsMinEntries: 2, validate: false).text == data.endContent, "\(name) dfs")
        #expect(oplog.checkoutValidated(dfsMinEntries: Int.max, validate: false).text == data.endContent, "\(name) lv")
    }
}
