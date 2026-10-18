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

    private var tree: ItemTree?
    private var tracking = false
    /// The version the tracker's `cur` states represent.
    private var curVersion: [LV] = []
    /// delTarget[lv - trackBase] = LV of the item deleted by delete event `lv`.
    private var delTarget: UnsafeMutablePointer<Int>?
    private var delTargetCapacity = 0
    private var trackBase = 0

    /// Statistics, useful for understanding what the walker did.
    private(set) var stats = Stats()
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

    deinit { delTarget?.deallocate() }

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
            laterMin[i] = Swift.min(laterMin[i + 1], entries[i].parents.first ?? -1)
            i -= 1
        }
        var critEnd = [LV](repeating: 0, count: n)
        var frontier: [LV] = []
        var region = 0, maxRegion = 0
        for i in 0..<n {
            let e = entries[i]
            let afterFirst = CausalGraph.advanceFrontier(frontier, vLast: e.version, parents: e.parents)
            let single = afterFirst.count == 1
            var ce = e.version
            if single {
                let bound = laterMin[i + 1]
                ce = bound == Int.max ? e.vEnd : Swift.min(e.vEnd, Swift.max(e.version, bound + 1))
            }
            critEnd[i] = ce
            frontier = CausalGraph.advanceFrontier(frontier, vLast: e.vEnd - 1, parents: e.parents)
            // Track the longest run of non-critical events (sizes tracker buffers).
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
        var ffVersion: [LV] = []

        oplog.content.withUnsafeBufferPointer { content in
            for (i, e) in cg.entries.enumerated() {
                let ce = critEnd[i]
                if ce > e.version {
                    // Critical prefix: the document is exactly at this event's parent
                    // version, so positions are valid as-is.
                    if tracking { stopTracking() }
                    fastForward(e.version, ce, content)
                    ffVersion = [ce - 1]
                }
                if ce < e.vEnd {
                    if !tracking { startTracking(at: ce, version: ffVersion, capacity: maxRegion) }
                    let parents = ce > e.version ? [ce - 1] : e.parents
                    trackedApply(ce, e.vEnd, parents: parents, content, toDoc: true)
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

    private func startTracking(at base: LV, version: [LV], capacity: Int) {
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
        curVersion = version
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
    func trackedApply(_ start: LV, _ end: LV, parents: [LV], _ content: UnsafeBufferPointer<Unicode.Scalar>, toDoc: Bool) {
        stats.tracked += end - start
        if curVersion != parents {
            let (retreat, advance) = oplog.cg.diff(curVersion, parents)
            for r in retreat.reversed() { applyDelta(r, -1) }
            for r in advance { applyDelta(r, +1) }
        }
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
        curVersion = [end - 1]
        if debugChecks { tree!.checkInvariants() }
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
