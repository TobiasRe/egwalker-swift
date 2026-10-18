#if canImport(Foundation) && !os(WASI)
import Foundation
#endif

/// Importers for the editing-trace formats used by the Eg-walker paper and the
/// diamond-types test suite. Both are JSON.
public enum TraceImport {
    // MARK: `dt export` format (conformance tests, *-raw.json traces)

    public struct DTExport: Decodable, Sendable {
        public struct Txn: Decodable, Sendable {
            public var agent: String
            public var seqStart: Int
            public var span: [Int]
            public var parents: [Int]
            public var ops: [Patch]
        }
        public var endContent: String
        public var txns: [Txn]
    }

    /// `[pos, delLen, insContent]`, optionally followed by `fwd` (false = the
    /// delete was a run of backspaces). Our own exporter writes `fwd`; the
    /// standard formats don't, in which case deletes are treated as forward.
    public struct Patch: Decodable, Sendable {
        public var pos: Int
        public var del: Int
        public var ins: String
        public var fwd: Bool
        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            pos = try c.decode(Int.self)
            del = try c.decode(Int.self)
            ins = try c.decode(String.self)
            fwd = c.isAtEnd ? true : ((try? c.decode(Bool.self)) ?? true)
        }
    }

    /// LVs in the export are reused directly (they're already topologically sorted).
    public static func oplog(from data: DTExport) -> OpLog {
        var oplog = OpLog()
        for txn in data.txns {
            precondition(txn.span[0] == oplog.count, "DT export spans must be contiguous: span \(txn.span) agent \(txn.agent) seq \(txn.seqStart) count \(oplog.count)")
            oplog.addPatches(agent: txn.agent, seqStart: txn.seqStart, parents: txn.parents,
                             patches: txn.ops.map { ($0.pos, $0.del, $0.ins, $0.fwd) })
        }
        return oplog
    }

    // MARK: `dt export-trace` format (the paper's S1..A2 datasets)

    public struct ConcurrentTrace: Decodable, Sendable {
        public struct Txn: Decodable, Sendable {
            public var parents: [Int]
            public var numChildren: Int
            public var agent: Int
            public var patches: [Patch]
        }
        public var kind: String
        public var endContent: String
        public var numAgents: Int
        public var txns: [Txn]
    }

    /// Agent names are the agent index left-padded to 7 characters, exactly like
    /// the TS reference test harness, so tie-breaking order is numeric.
    public static func agentName(_ i: Int) -> String {
        let s = String(i)
        return String(repeating: " ", count: Swift.max(0, 7 - s.count)) + s
    }

    public static func oplog(from trace: ConcurrentTrace) -> OpLog {
        precondition(trace.kind == "concurrent", "Not a concurrent editing trace")
        var oplog = OpLog()
        var nextSeq = [Int](repeating: 0, count: trace.numAgents)
        var lastLVOfTxn = [LV]()
        lastLVOfTxn.reserveCapacity(trace.txns.count)
        for txn in trace.txns {
            let parents = txn.parents.map { lastLVOfTxn[$0] }
            let seqStart = nextSeq[txn.agent]
            oplog.addPatches(agent: agentName(txn.agent), seqStart: seqStart, parents: parents,
                             patches: txn.patches.map { ($0.pos, $0.del, $0.ins, true) })
            nextSeq[txn.agent] = oplog.cg.nextSeq(forAgent: agentName(txn.agent))
            lastLVOfTxn.append(oplog.count - 1)
        }
        return oplog
    }

    // File loaders need Foundation. They are left out of WebAssembly builds so the
    // library doesn't pull Foundation (and its ICU data) into the binary. The
    // trace types are plain `Decodable`, so callers can decode them themselves.
    #if canImport(Foundation) && !os(WASI)
    public static func loadDTExport(_ url: URL) throws -> DTExport {
        try JSONDecoder().decode(DTExport.self, from: Data(contentsOf: url))
    }
    public static func loadDTExports(_ url: URL) throws -> [DTExport] {
        try JSONDecoder().decode([DTExport].self, from: Data(contentsOf: url))
    }
    public static func loadConcurrentTrace(_ url: URL) throws -> ConcurrentTrace {
        try JSONDecoder().decode(ConcurrentTrace.self, from: Data(contentsOf: url))
    }
    #endif
}
