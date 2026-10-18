/// The optimized Eg-walker.
///
/// The core idea, in three sentences:
/// 1. Replay events in local-version order (a topological sort of the graph).
/// 2. If an event is *critical* — everything before it is in its history and
///    everything after it has it in its history — no concurrency can ever touch
///    it, so its integer position is already correct: apply it straight to the
///    text ("fast-forward"), with no CRDT bookkeeping at all.
/// 3. Only between critical events do we build CRDT state (the `ItemTree`), and
///    we throw it away again at the next critical event.
///
/// Sequential traces (one person typing) therefore never build a CRDT. Highly
/// concurrent traces build small, short-lived ones.
final class Walker {
    let oplog: OpLog
    let doc: GapBuffer

    // Performance note: `@exclusivity(unchecked)` turns off Swift's *dynamic*
    // exclusivity checks for these fields. The walker is single-threaded and never
    // passes these properties inout while also reading them, so the checks can't
    // fire — but they cost ~10% of the runtime in the hot loop. The test suite
    // (incl. the debug build, where the rest of the checks stay on) guards this.
    @exclusivity(unchecked) private var tree: ItemTree?
    @exclusivity(unchecked) private var tracking = false
    /// The version the tracker's `cur` states represent.
    @exclusivity(unchecked) private var curVersion = ContiguousArray<LV>()
    /// Scratch for `moveTracker`: queue entries encoded as `lv << 2 | flag`.
    @exclusivity(unchecked) private var diffQueue: UnsafeMutablePointer<Int> = .allocate(capacity: 64)
    @exclusivity(unchecked) private var diffQueueCap = 64
    @exclusivity(unchecked) private var diffAdvance = ContiguousArray<LVRange>()
    /// delTarget[lv - trackBase] = LV of the item deleted by delete event `lv`.
    @exclusivity(unchecked) private var delTarget: UnsafeMutablePointer<Int>?
    @exclusivity(unchecked) private var delTargetCapacity = 0
    @exclusivity(unchecked) private var trackBase = 0

    /// Statistics, useful for understanding what the walker did.
    @exclusivity(unchecked) private(set) var stats = Stats()
    struct Stats {
        var fastForwarded = 0
        var tracked = 0
        var trackingSessions = 0
        var maxTrackedItems = 0
        var peakTreeBytes = 0
    }

    /// When true, the tree validates every invariant after each step (tests only).
    var debugChecks = false

    init(oplog: OpLog, doc: GapBuffer) {
        self.oplog = oplog
        self.doc = doc
    }

    deinit { delTarget?.deallocate(); diffQueue.deallocate() }

    // MARK: - Planning

    /// For every causal-graph entry, the end of its critical prefix: events
    /// `[entry.version, critEnd[i])` are critical.
    ///
    /// Event x is critical iff
    ///  (a) after processing 0...x the frontier is exactly [x] (everything earlier
    ///      is an ancestor of x), and
    ///  (b) no later event has a parent < x (so everything later descends from x;
    ///      parents are antichains, so this is exact, and if they weren't we'd
    ///      only lose an optimisation, never correctness).
    /// Inside one entry (a) holds for all events or none, and (b) holds for a
    /// prefix, so critical events form a prefix of each entry.
    static func plan(_ cg: CausalGraph) -> (critEnd: [LV], maxRegion: Int) {
        let entries = cg.entries
        let n = entries.count
        // laterMin[i] = min parent over entries[i...]; a root event counts as -1.
        var laterMin = [Int](repeating: Int.max, count: n + 1)
        var i = n - 1
        while i >= 0 {
            laterMin[i] = Swift.min(laterMin[i + 1], cg.parents(entries[i]).first ?? -1)
            i -= 1
        }
        var critEnd = [LV](repeating: 0, count: n)
        // The frontier as an unordered set; we only ever need its size.
        var frontier = ContiguousArray<LV>()
        var region = 0, maxRegion = 0
        for i in 0..<n {
            let e = entries[i]
            let ps = cg.parents(e)
            // Remove parents from the frontier, add this event.
            var j = 0
            while j < frontier.count {
                if ps.contains(frontier[j]) { frontier.swapAt(j, frontier.count - 1); frontier.removeLast() }
                else { j += 1 }
            }
            frontier.append(e.vEnd - 1)
            let single = frontier.count == 1
            var ce = e.version
            if single {
                let bound = laterMin[i + 1]
                ce = bound == Int.max ? e.vEnd : Swift.min(e.vEnd, Swift.max(e.version, bound + 1))
            }
            critEnd[i] = ce
            if ce > e.version { region = 0 }
            region += e.vEnd - ce
            maxRegion = Swift.max(maxRegion, region)
        }
        return (critEnd, maxRegion)
    }

    // MARK: - Checkout

    func checkout() {
        let cg = oplog.cg
        let (critEnd, maxRegion) = Self.plan(cg)
        var ffVersion = ContiguousArray<LV>()
        var single = ContiguousArray<LV>([0])

        oplog.content.withUnsafeBufferPointer { content in
            for (i, e) in cg.entries.enumerated() {
                let ce = critEnd[i]
                if ce > e.version {
                    // Critical prefix: the document is exactly at this event's parent
                    // version, so positions are valid as-is.
                    if tracking { stopTracking() }
                    fastForward(e.version, ce, content)
                    ffVersion.removeAll(keepingCapacity: true)
                    ffVersion.append(ce - 1)
                }
                if ce < e.vEnd {
                    if !tracking { startTracking(at: ce, version: ffVersion[...], capacity: maxRegion) }
                    if ce > e.version {
                        single[0] = ce - 1
                        trackedApply(ce, e.vEnd, parents: single[...], content, toDoc: true)
                    } else {
                        trackedApply(ce, e.vEnd, parents: cg.parents(e), content, toDoc: true)
                    }
                }
            }
        }
        if tracking { stopTracking() }
    }

    // MARK: - Fast-forward

    private func fastForward(_ start: LV, _ end: LV, _ content: UnsafeBufferPointer<Unicode.Scalar>) {
        stats.fastForwarded += end - start
        forEachOpPiece(start, end) { run, a, b in
            switch run.kind {
            case .insert:
                let from = run.contentStart + (a - run.lvStart)
                doc.insert(UnsafeBufferPointer(rebasing: content[from..<(from + b - a)]), at: run.pos(at: a - run.lvStart))
            case .delete:
                // fwd: all at pos. Backspace: the lowest position in the piece.
                let lowest = run.fwd ? run.pos : run.pos(at: b - 1 - run.lvStart)
                doc.delete(at: lowest, count: b - a)
            }
        }
    }

    /// Calls `body(run, a, b)` for each op run overlapping [start, end), clipped.
    @inline(__always)
    private func forEachOpPiece(_ start: LV, _ end: LV, _ body: (OpRun, LV, LV) -> Void) {
        var ri = oplog.runIndex(start)
        var lv = start
        while lv < end {
            let run = oplog.runs[ri]
            let b = Swift.min(end, run.lvEnd)
            body(run, lv, b)
            lv = b
            ri += 1
        }
    }

    // MARK: - Tracking

    private func startTracking(at base: LV, version: ArraySlice<LV>, capacity: Int) {
        tracking = true
        stats.trackingSessions += 1
        trackBase = base
        let t: ItemTree
        if let existing = tree { t = existing } else {
            t = ItemTree(lvCapacity: capacity)
            tree = t
        }
        t.reset(lvBase: base, lvCount: capacity)
        if capacity > delTargetCapacity {
            delTarget?.deallocate()
            delTarget = .allocate(capacity: capacity)
            delTargetCapacity = capacity
        }
        let docLen = doc.count
        if docLen > 0 {
            t.insertSpan(Span(lv: placeholderBase, originLeft: -1, rightParent: -1, len: Int32(docLen),
                              cur: ItemState.inserted, endDeleted: false), leaf: t.firstLeaf, at: 0)
        }
        curVersion.removeAll(keepingCapacity: true)
        curVersion.append(contentsOf: version)
    }

    private func stopTracking() {
        tracking = false
        if let t = tree {
            stats.maxTrackedItems = Swift.max(stats.maxTrackedItems, Int(t.total.items))
            stats.peakTreeBytes = Swift.max(stats.peakTreeBytes, t.allocatedBytes)
        }
    }

    /// Applies events [start, end) (one causal-graph run with the given parents)
    /// through the CRDT.
    func trackedApply(_ start: LV, _ end: LV, parents: ArraySlice<LV>, _ content: UnsafeBufferPointer<Unicode.Scalar>, toDoc: Bool) {
        stats.tracked += end - start
        if !curVersion.elementsEqual(parents) { moveTracker(to: parents) }
        forEachOpPiece(start, end) { run, a, b in
            switch run.kind {
            case .insert:
                let from = run.contentStart + (a - run.lvStart)
                trackedInsert(lv: a, count: b - a, pos: run.pos(at: a - run.lvStart),
                              UnsafeBufferPointer(rebasing: content[from..<(from + b - a)]), toDoc: toDoc)
            case .delete:
                if run.fwd {
                    trackedDelete(lv: a, count: b - a, pos: run.pos, reversed: false, toDoc: toDoc)
                } else {
                    trackedDelete(lv: a, count: b - a, pos: run.pos(at: b - 1 - run.lvStart), reversed: true, toDoc: toDoc)
                }
            }
        }
        curVersion.removeAll(keepingCapacity: true)
        curVersion.append(end - 1)
        if debugChecks { tree!.checkInvariants() }
    }

    /// Moves the tracker from `curVersion` to `target`: retreat every event only
    /// in curVersion's history, advance every event only in target's history.
    ///
    /// Same algorithm as `CausalGraph.diff`, but allocation-free: the queue is a
    /// tiny sorted array (it rarely holds more than a handful of versions), and
    /// retreats are applied the moment they're discovered (they come out in
    /// descending order, which is exactly the order retreating needs).
    private func moveTracker(to target: ArraySlice<LV>) {
        let cg = oplog.cg
        diffAdvance.removeAll(keepingCapacity: true)
        // Ascending sorted queue of (lv << 2 | flag). Max is at the end.
        var q = diffQueue
        var qCount = 0
        var numShared = 0
        let fA = Int(DiffFlag.a.rawValue), fB = Int(DiffFlag.b.rawValue), fShared = Int(DiffFlag.shared.rawValue)

        @inline(__always) func enq(_ v: LV, _ flag: Int) {
            var i = qCount
            while i > 0 && (q[i - 1] >> 2) > v { i -= 1 }
            if i > 0 && (q[i - 1] >> 2) == v {
                let cur = q[i - 1] & 3
                if flag != cur && cur != fShared {
                    q[i - 1] = (v << 2) | fShared
                    numShared += 1
                }
                return
            }
            if qCount == diffQueueCap {
                let nq = UnsafeMutablePointer<Int>.allocate(capacity: diffQueueCap * 2)
                nq.update(from: q, count: qCount)
                q.deallocate()
                q = nq
                diffQueue = nq
                diffQueueCap *= 2
            }
            memmoveElements(q + i + 1, q + i, qCount - i)
            q[i] = (v << 2) | flag
            qCount += 1
            if flag == fShared { numShared += 1 }
        }

        var pendingRetreat = LVRange(0, 0)
        @inline(__always) func markRun(_ start: LV, _ endInclusive: LV, _ flag: Int) {
            let end = endInclusive + 1
            if flag == fA {
                if !pendingRetreat.isEmpty && pendingRetreat.start == end { pendingRetreat.start = start }
                else {
                    if !pendingRetreat.isEmpty { applyDelta(pendingRetreat, -1) }
                    pendingRetreat = LVRange(start, end)
                }
            } else if flag == fB {
                if let last = diffAdvance.last, last.start == end { diffAdvance[diffAdvance.count - 1].start = start }
                else { diffAdvance.append(LVRange(start, end)) }
            }
        }

        for v in curVersion { enq(v, fA) }
        for v in target { enq(v, fB) }

        while qCount > numShared {
            qCount -= 1
            var v = q[qCount] >> 2
            var flag = q[qCount] & 3
            if flag == fShared { numShared -= 1 }
            let e = cg.findEntry(v)
            while qCount > 0 && (q[qCount - 1] >> 2) >= e.version {
                qCount -= 1
                let v2 = q[qCount] >> 2
                let flag2 = q[qCount] & 3
                if flag2 == fShared { numShared -= 1 }
                if flag2 != flag {
                    markRun(v2 + 1, v, flag)
                    v = v2
                    flag = fShared
                }
            }
            markRun(e.version, v, flag)
            for p in cg.parents(e) { enq(p, flag) }
        }
        if !pendingRetreat.isEmpty { applyDelta(pendingRetreat, -1) }
        var k = diffAdvance.count - 1
        while k >= 0 { applyDelta(diffAdvance[k], +1); k -= 1 }
    }

    /// Retreats (-1) or advances (+1) every event in `r`.
    private func applyDelta(_ r: LVRange, _ delta: Int32) {
        let tree = self.tree!
        precondition(r.start >= trackBase, "retreat/advance below the tracking base")
        forEachOpPiece(r.start, r.end) { run, a, b in
            switch run.kind {
            case .insert:
                tree.addToCur(lv: a, count: b - a, delta: delta)
            case .delete:
                // Group consecutive targets (ascending or descending) into ranges.
                let dt = delTarget!
                var i = a
                while i < b {
                    let t0 = dt[i - trackBase]
                    var j = i + 1
                    if j < b && dt[j - trackBase] == t0 + 1 {
                        while j < b && dt[j - trackBase] == t0 + (j - i) { j += 1 }
                        tree.addToCur(lv: t0, count: j - i, delta: delta)
                    } else if j < b && dt[j - trackBase] == t0 - 1 {
                        while j < b && dt[j - trackBase] == t0 - (j - i) { j += 1 }
                        tree.addToCur(lv: t0 - (j - i - 1), count: j - i, delta: delta)
                    } else {
                        tree.addToCur(lv: t0, count: 1, delta: delta)
                    }
                    i = j
                }
            }
        }
    }

    private func trackedInsert(lv: LV, count n: Int, pos: Int, _ content: UnsafeBufferPointer<Unicode.Scalar>, toDoc: Bool) {
        let tree = self.tree!
        var cursor = tree.cursorAfterCurPos(pos)

        // Origin left: the item right before the cursor.
        let originLeft: Int
        if pos == 0 { originLeft = -1 } else {
            originLeft = tree.span(cursor.leaf, cursor.idx).lv + cursor.off - 1
        }

        // Find the first item at/after the cursor that isn't NYI.
        var rightParent = -1
        var firstLeaf = cursor.leaf, firstIdx = cursor.idx
        var atEnd = false
        var nextIsNYI = false
        do {
            var leaf = cursor.leaf, idx = cursor.idx, off = cursor.off
            // Normalise to a real item position.
            if idx >= tree.len(leaf) || off >= Int(tree.span(leaf, idx).len) {
                off = 0
                if idx >= tree.len(leaf) { idx -= 1 }  // so nextSpan steps correctly
                if !tree.nextSpan(&leaf, &idx) { atEnd = true }
            }
            firstLeaf = leaf; firstIdx = idx
            if !atEnd {
                nextIsNYI = tree.span(leaf, idx).cur == ItemState.notYetInserted
                var s = tree.span(leaf, idx)
                while s.cur == ItemState.notYetInserted {
                    off = 0
                    if !tree.nextSpan(&leaf, &idx) { s = Span(lv: -1, originLeft: 0, rightParent: 0, len: 0, cur: -1, endDeleted: true); break }
                    s = tree.span(leaf, idx)
                }
                if s.len > 0 && s.cur != ItemState.notYetInserted {
                    rightParent = s.originLeft(at: off) == originLeft ? s.lv + off : -1
                }
            }
        }

        if nextIsNYI {
            integrate(lv: lv, originLeft: originLeft, rightParent: rightParent,
                      cursor: &cursor, firstLeaf: firstLeaf, firstIdx: firstIdx)
        }

        // Insert the new run at the cursor.
        let newSpan = Span(lv: lv, originLeft: originLeft, rightParent: rightParent, len: Int32(n),
                           cur: ItemState.inserted, endDeleted: false)
        var leaf = cursor.leaf
        var idx = cursor.idx
        if idx < tree.len(leaf) {
            let s = tree.span(leaf, idx)
            if cursor.off >= Int(s.len) { idx += 1 }
            else if cursor.off > 0 {
                let r = tree.splitSpan(leaf: leaf, idx: idx, off: cursor.off)
                leaf = r.leaf; idx = r.idx
            }
        }
        if idx > 0 && ItemTree.canMerge(tree.span(leaf, idx - 1), newSpan) {
            tree.modifySpan(leaf: leaf, idx: idx - 1) { $0.len += Int32(n) }
            tree.markLeaf(lv: lv, count: n, leaf: leaf)
        } else {
            tree.insertSpan(newSpan, leaf: leaf, at: idx)
        }
        if toDoc { doc.insert(content, at: cursor.endPos) }
    }

    /// YjsMod / Fugue integration, at span granularity. See ReferenceWalker.integrate.
    private func integrate(lv: LV, originLeft: Int, rightParent: Int, cursor: inout TreeCursor,
                           firstLeaf: Int32, firstIdx: Int) {
        let tree = self.tree!
        let cg = oplog.cg
        let leftRank = tree.rank(leaf: cursor.leaf, idx: cursor.idx, off: cursor.off) - 1
        let rightRank = rightParent == -1 ? Int(tree.total.items) : tree.rank(ofLV: rightParent)
        var scanning = false
        var leaf = firstLeaf, idx = firstIdx
        var scanEndPos = cursor.endPos

        while true {
            let other = tree.span(leaf, idx)
            if other.cur != ItemState.notYetInserted { break }
            let oleftRank = tree.rank(ofLV: other.originLeft)
            if oleftRank < leftRank { break }
            if oleftRank == leftRank {
                let orightRank = other.rightParent == -1 ? Int(tree.total.items) : tree.rank(ofLV: other.rightParent)
                if orightRank == rightRank && cg.compareLV(lv, other.lv) < 0 { break }
                scanning = orightRank < rightRank
            }
            if !other.endDeleted { scanEndPos += Int(other.len) }
            if !scanning {
                cursor = TreeCursor(leaf: leaf, idx: idx, off: Int(other.len), endPos: scanEndPos)
            }
            if !tree.nextSpan(&leaf, &idx) { break }
        }
    }

    private func trackedDelete(lv: LV, count n: Int, pos: Int, reversed: Bool, toDoc: Bool) {
        let tree = self.tree!
        let dt = delTarget!
        let c = tree.cursorAtVisible(pos)
        var leaf = c.leaf, idx = c.idx, off = c.off
        var endPos = c.endPos
        var k = 0
        while k < n {
            let s = tree.span(leaf, idx)
            if s.cur != ItemState.inserted {
                if !s.endDeleted { endPos += Int(s.len) - off }
                off = 0
                let ok = tree.nextSpan(&leaf, &idx)
                precondition(ok, "delete ran off the end of the document")
                continue
            }
            let m = Swift.min(n - k, Int(s.len) - off)
            let loc = tree.isolate(leaf: leaf, idx: idx, off: off, count: m)
            leaf = loc.leaf; idx = loc.idx
            let targetStart = s.lv + off
            for j in 0..<m {
                let delLV = reversed ? lv + n - 1 - (k + j) : lv + k + j
                dt[delLV - trackBase] = targetStart + j
            }
            if !s.endDeleted && toDoc { doc.delete(at: endPos, count: m) }
            tree.modifySpan(leaf: leaf, idx: idx) { $0.cur = 1; $0.endDeleted = true }
            // Keep the tree compact: deleted runs merge with deleted neighbours.
            tree.tryMergeRight(leaf: leaf, idx: idx)
            if idx > 0 && tree.tryMergeRight(leaf: leaf, idx: idx - 1) { idx -= 1 }
            k += m
            off = 0
            if k < n {
                let ok = tree.nextSpan(&leaf, &idx)
                precondition(ok, "delete ran off the end of the document")
            }
        }
    }
}

// MARK: - Public API

extension OpLog {
    /// Replays the whole oplog into a document (the optimized walker).
    public func checkout() -> Branch {
        let doc = GapBuffer(capacity: Swift.max(64, count / 4))
        let walker = Walker(oplog: self, doc: doc)
        walker.checkout()
        return Branch(scalars: doc.scalars, version: cg.heads)
    }

    /// Replays the oplog and returns walker statistics alongside the text (for
    /// benchmarks and tests).
    public func checkoutWithStats() -> (text: [Unicode.Scalar], stats: WalkerStats) {
        let doc = GapBuffer(capacity: Swift.max(64, count / 4))
        let walker = Walker(oplog: self, doc: doc)
        walker.checkout()
        let s = walker.stats
        return (doc.scalars, WalkerStats(fastForwarded: s.fastForwarded, tracked: s.tracked,
                                         trackingSessions: s.trackingSessions, maxTrackedItems: s.maxTrackedItems,
                                         peakTreeBytes: s.peakTreeBytes, docBytes: doc.allocatedBytes))
    }

    /// Checkout that only reports the document length (no text materialisation).
    public func checkoutLength() -> Int {
        let doc = GapBuffer(capacity: Swift.max(64, count / 4))
        let walker = Walker(oplog: self, doc: doc)
        walker.checkout()
        return doc.count
    }
}

public struct WalkerStats: Sendable, CustomStringConvertible {
    public var fastForwarded: Int
    public var tracked: Int
    public var trackingSessions: Int
    public var maxTrackedItems: Int
    public var peakTreeBytes: Int
    public var docBytes: Int
    public var description: String {
        "ff=\(fastForwarded) tracked=\(tracked) sessions=\(trackingSessions) maxItems=\(maxTrackedItems) treeBytes=\(peakTreeBytes) docBytes=\(docBytes)"
    }
}

extension OpLog {
    /// Checkout with full tree validation after every step. Slow; tests only.
    func checkoutValidated() -> (text: String, stats: Walker.Stats) {
        let doc = GapBuffer()
        let walker = Walker(oplog: self, doc: doc)
        walker.debugChecks = true
        walker.checkout()
        return (Branch(scalars: doc.scalars).text, walker.stats)
    }
}

/// A checked-out document: the text produced by replaying an oplog.
public final class TextDocument: @unchecked Sendable {
    let buffer: GapBuffer
    public let version: [LV]
    init(buffer: GapBuffer, version: [LV]) { self.buffer = buffer; self.version = version }
    /// Length in Unicode scalars.
    public var count: Int { buffer.count }
    public var scalars: [Unicode.Scalar] { buffer.scalars }
    public var text: String { Branch(scalars: buffer.scalars).text }
}

extension OpLog {
    /// Replays the oplog into a `TextDocument` without materialising a String.
    public func checkoutDocument() -> TextDocument {
        let doc = GapBuffer(capacity: Swift.max(64, count / 8))
        let walker = Walker(oplog: self, doc: doc)
        walker.checkout()
        return TextDocument(buffer: doc, version: cg.heads)
    }
}
