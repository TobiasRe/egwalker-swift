/// The kind of a list operation.
public enum OpKind: UInt8, Sendable { case insert = 0, delete = 1 }

/// A run of operations stored in the oplog (run-length encoded).
///
/// Each individual operation inserts or deletes exactly one character, but humans
/// type and delete in runs. So we store:
/// - inserts: `len` characters inserted at `pos, pos+1, pos+2, ...`
/// - forward deletes (the Delete key): `len` deletes all at `pos`
/// - backward deletes (Backspace): deletes at `pos+len-1, pos+len-2, ..., pos`
///
/// Positions are in Unicode scalars, measured in the document *as it was when the
/// operation was made* (at its parent version). That's the whole trick of
/// Eg-walker: operations keep plain integer positions, like OT, and we only
/// transform them when concurrency forces us to.

struct OpRun: Sendable {
    var lvStart: LV
    var len: Int32
    var kind: OpKind
    /// Deletes only: true = all at `pos` (forward), false = backspace pattern.
    var fwd: Bool
    var pos: Int
    /// Inserts only: offset of the first character in `OpLog.content`.
    var contentStart: Int

    var lvEnd: LV { lvStart + Int(len) }

    /// Position of the i-th operation in this run.
    func pos(at i: Int) -> Int {
        switch kind {
        case .insert: return pos + i
        case .delete: return fwd ? pos : pos + Int(len) - 1 - i
        }
    }
}

/// A single operation, as seen by the walker.
public struct ListOp: Equatable, Sendable {
    public var kind: OpKind
    public var pos: Int
    public var content: Unicode.Scalar?
}

/// The operation log: the causal graph plus the operation each event performs.
///
/// This is the only state Eg-walker needs to persist. Document text and all CRDT
/// metadata can always be regenerated from it — that's the "event graph is the
/// source of truth" idea from the paper.
public struct OpLog: Sendable {
    public internal(set) var cg = CausalGraph()
    var runs: ContiguousArray<OpRun> = []
    var content: ContiguousArray<Unicode.Scalar> = []

    public init() {}

    /// Number of operations (= number of events).
    public var count: Int { cg.nextLV }
    public var runCount: Int { runs.count }

    // MARK: Local edits

    /// Inserts `text` at `pos` as `agent`, on top of everything this oplog knows.
    @discardableResult
    public mutating func insert(agent: String, at pos: Int, _ text: String) -> LVRange {
        let scalars = Array(text.unicodeScalars)
        precondition(!scalars.isEmpty, "Cannot insert empty text")
        let seq = cg.nextSeq(forAgent: agent)
        let range = cg.add(agent: agent, seqStart: seq, seqEnd: seq + scalars.count, parents: cg.heads)!
        pushInsert(lv: range.start, pos: pos, scalars[...])
        return range
    }

    /// Deletes `len` characters starting at `pos` as `agent`.
    @discardableResult
    public mutating func delete(agent: String, at pos: Int, len: Int = 1) -> LVRange {
        precondition(len > 0, "Invalid delete length")
        let seq = cg.nextSeq(forAgent: agent)
        let range = cg.add(agent: agent, seqStart: seq, seqEnd: seq + len, parents: cg.heads)!
        pushDelete(lv: range.start, pos: pos, len: len, fwd: true)
        return range
    }

    // MARK: Remote edits

    /// Adds a single remote operation. Returns false if we already had it.
    @discardableResult
    public mutating func push(id: RawVersion, parents: [RawVersion], op: ListOp) -> Bool {
        guard let range = cg.addRaw(id, len: 1, parents: parents) else { return false }
        switch op.kind {
        case .insert: pushInsert(lv: range.start, pos: op.pos, [op.content!][...])
        case .delete: pushDelete(lv: range.start, pos: op.pos, len: 1, fwd: true)
        }
        return true
    }

    /// Low-level: adds events `agent, seqStart..<seqEnd` with LV parents and their
    /// operations (in order). Used by importers. Ops are `(pos, delLen, insText)`
    /// patches, like the editing-trace format.
    public mutating func addPatches(agent: String, seqStart: Int, parents: [LV],
                                    patches: [(pos: Int, del: Int, ins: String, fwd: Bool)]) {
        var total = 0
        var scalarPatches: [(Int, Int, [Unicode.Scalar], Bool)] = []
        scalarPatches.reserveCapacity(patches.count)
        for p in patches {
            let s = Array(p.ins.unicodeScalars)
            precondition((p.del > 0) != !s.isEmpty, "Patch must be an insert or a delete")
            total += p.del + s.count
            scalarPatches.append((p.pos, p.del, s, p.fwd))
        }
        guard let range = cg.add(agent: agent, seqStart: seqStart, seqEnd: seqStart + total, parents: parents) else { return }
        precondition(range.count == total, "Partially known spans are not supported by addPatches")
        var lv = range.start
        for (pos, del, ins, fwd) in scalarPatches {
            if del > 0 {
                pushDelete(lv: lv, pos: pos, len: del, fwd: fwd || del == 1)
                lv += del
            } else {
                pushInsert(lv: lv, pos: pos, ins[...])
                lv += ins.count
            }
        }
    }

    // MARK: Run-length encoding of operations

    mutating func pushInsert(lv: LV, pos: Int, _ scalars: ArraySlice<Unicode.Scalar>) {
        precondition(lv == (runs.last?.lvEnd ?? 0), "ops must be pushed in LV order")
        let contentStart = content.count
        content.append(contentsOf: scalars)
        if var last = runs.last, last.kind == .insert,
           last.lvEnd == lv, last.pos + Int(last.len) == pos,
           last.contentStart + Int(last.len) == contentStart,
           Int(last.len) + scalars.count < Int(Int32.max) {
            last.len += Int32(scalars.count)
            runs[runs.count - 1] = last
        } else {
            runs.append(OpRun(lvStart: lv, len: Int32(scalars.count), kind: .insert, fwd: true, pos: pos, contentStart: contentStart))
        }
    }

    /// `fwd == false` means a backspace run: deletes at pos+len-1, pos+len-2, ..., pos.
    mutating func pushDelete(lv: LV, pos: Int, len: Int, fwd: Bool) {
        precondition(lv == (runs.last?.lvEnd ?? 0), "ops must be pushed in LV order")
        let fwd = fwd || len == 1
        if var last = runs.last, last.kind == .delete, last.lvEnd == lv {
            if fwd && last.fwd && pos == last.pos {
                // Delete key pressed again at the same spot.
                last.len += Int32(len); runs[runs.count - 1] = last; return
            }
            let lastPos = last.pos(at: Int(last.len) - 1)
            if !(fwd && len > 1) && pos + len == lastPos && (last.len == 1 || !last.fwd) {
                // Backspace continuing to the left.
                last.fwd = false; last.pos = pos; last.len += Int32(len)
                runs[runs.count - 1] = last; return
            }
        }
        runs.append(OpRun(lvStart: lv, len: Int32(len), kind: .delete, fwd: fwd, pos: pos, contentStart: 0))
    }

    // MARK: Reading

    /// Index of the run containing `lv`.
    func runIndex(_ lv: LV) -> Int {
        var lo = 0, hi = runs.count
        while lo < hi {
            let mid = (lo + hi) &>> 1
            let r = runs[mid]
            if lv < r.lvStart { hi = mid } else if lv >= r.lvEnd { lo = mid + 1 } else { return mid }
        }
        preconditionFailure("Unknown LV \(lv)")
    }

    /// The operation performed by event `lv`.
    public func op(at lv: LV) -> ListOp {
        let r = runs[runIndex(lv)]
        let i = lv - r.lvStart
        return ListOp(kind: r.kind, pos: r.pos(at: i), content: r.kind == .insert ? content[r.contentStart + i] : nil)
    }

    // MARK: Sync

    /// Copies every event `other` has and we don't (like a network sync).
    public mutating func merge(from other: OpLog) {
        for (ri, run) in other.runs.enumerated() {
            _ = ri
            var lv = run.lvStart
            while lv < run.lvEnd {
                // Process the part of the run inside one CG entry.
                let entryIdx = other.cg.findEntryIndex(lv)
                let e = other.cg.entries[entryIdx]
                let end = Swift.min(run.lvEnd, e.vEnd)
                let raw = other.cg.lvToRaw(lv)
                let parents = (lv == e.version ? e.parents : [lv - 1]).map { other.cg.lvToRaw($0) }
                let lvParents = parents.map { cg.rawToLV($0)! }
                if let added = cg.add(agent: raw.agent, seqStart: raw.seq, seqEnd: raw.seq + (end - lv), parents: lvParents) {
                    // Some prefix might have been known already.
                    let skip = (end - lv) - added.count
                    for i in 0..<added.count {
                        let srcIdx = lv - run.lvStart + skip + i
                        switch run.kind {
                        case .insert:
                            pushInsert(lv: added.start + i, pos: run.pos(at: srcIdx),
                                       other.content[(run.contentStart + srcIdx)...(run.contentStart + srcIdx)])
                        case .delete:
                            pushDelete(lv: added.start + i, pos: run.pos(at: srcIdx), len: 1, fwd: true)
                        }
                    }
                }
                lv = end
            }
        }
    }

    /// The raw IDs of the current frontier.
    public var latestVersion: [RawVersion] { cg.heads.map { cg.lvToRaw($0) } }
}
