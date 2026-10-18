import Testing
@testable import EgWalker

@Suite("Reference walker (oracle)")
struct ReferenceWalkerTests {
    @Test func simpleLocalEditing() {
        var oplog = OpLog()
        oplog.insert(agent: "seph", at: 0, "hi")
        oplog.insert(agent: "seph", at: 2, " there")
        oplog.delete(agent: "seph", at: 0, len: 1)
        #expect(ReferenceWalker.checkout(oplog).text == "i there")
    }

    @Test func concurrentInsertsAreOrderedByAgent() {
        var a = OpLog(), b = OpLog()
        a.insert(agent: "alice", at: 0, "A")
        b.insert(agent: "bob", at: 0, "B")
        a.merge(from: b)
        b.merge(from: a)
        let ta = ReferenceWalker.checkout(a).text
        #expect(ta == ReferenceWalker.checkout(b).text)
        #expect(ta == "AB")
    }

    @Test func conformanceSuite() {
        let runs = Fixtures.conformance
        #expect(runs.count > 100)
        for (i, run) in runs.enumerated() {
            let oplog = TraceImport.oplog(from: run)
            oplog.cg.checkInvariants()
            let result = ReferenceWalker.checkout(oplog).text
            #expect(result == run.endContent, "conformance case \(i)")
            if result != run.endContent { return }
        }
    }

    @Test func friendsForeverRawTrace() throws {
        let data = try TraceImport.loadDTExport(Fixtures.url("ff-raw.json"))
        let oplog = TraceImport.oplog(from: data)
        #expect(ReferenceWalker.checkout(oplog).text == data.endContent)
    }
}
