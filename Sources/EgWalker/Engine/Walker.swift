import Foundation

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

    // Performance notes.
    //
    // 1. `@exclusivity(unchecked)` turns off Swift's *dynamic* exclusivity checks
    //    for these fields. The walker is single-threaded and never passes these
    //    properties inout while also reading them, so the checks can never fire —
    //    but they cost a few percent of the runtime (1–4% re-measured, see
    //    docs/performance.md).
    // 2. During `checkout()` we read the oplog through raw buffer pointers
    //    (`entries`, `parentPool`, `runs`). Going through the Swift arrays would
    //    retain/release their storage on every access; through pointers it's a
    //    plain load. The pointers are only valid inside `checkout()`'s
    //    `withUnsafeBufferPointer` scopes, and nothing escapes them.
    @exclusivity(unchecked) private var entries = UnsafeBufferPointer<CGEntry>(start: nil, count: 0)
    @exclusivity(unchecked) private var parentPool = UnsafeBufferPointer<LV>(start: nil, count: 0)
    @exclusivity(unchecked) private var runs = UnsafeBufferPointer<OpRun>(start: nil, count: 0)
    @exclusivity(unchecked) private var content = UnsafeBufferPointer<Unicode.Scalar>(start: nil, count: 0)

    @exclusivity(unchecked) private var tree: ItemTree?
    @exclusivity(unchecked) private var tracking = false
    /// The version the tracker's `cur` states represent (a small set of LVs).
    @exclusivity(unchecked) private var curVersion = SmallVersion()
    /// Scratch for `moveTracker`: queue entries encoded as `lv << 2 | flag`.
    @exclusivity(unchecked) private var diffQueue = UnsafeMutablePointer<Int>.allocate(capacity: 64)
    @exclusivity(unchecked) private var diffQueueCap = 64
    @exclusivity(unchecked) private var diffAdvance = ContiguousArray<LVRange>()
    /// delTarget[lv - trackBase] = the item deleted by delete event `lv`, encoded
    /// as Int32 to halve memory: `target - trackBase` for real items, and
    /// `-(k + 1)` for placeholder k. (The paper's A2 trace tracks ~700k events at
    /// once; at 8 bytes per entry this array alone was 5.6 MB.)
    @exclusivity(unchecked) private var delTarget: UnsafeMutablePointer<Int32>?
    @exclusivity(unchecked) private var delTargetCapacity = 0
    @exclusivity(unchecked) private var trackBase = 0
    /// False while replaying already-applied events to rebuild CRDT state
    /// (incremental merge): the tracker changes, the document must not.
    @exclusivity(unchecked) private var docEnabled = true
    /// One-element parent list, for slices that start mid-entry.
    private let oneParent = UnsafeMutablePointer<LV>.allocate(capacity: 1)

    /// Statistics, useful for understanding what the walker did.
    @exclusivity(unchecked) private(set) var stats = Stats()
    struct Stats {
        var fastForwarded = 0
        var tracked = 0
        var trackingSessions = 0
        var maxTrackedItems = 0
        var peakTreeBytes = 0
        var retreated = 0
        var advanced = 0
    }

    /// Concurrent regions with at least this many entries are replayed depth-first
    /// (see `processRegion`); smaller ones in LV order.
    ///
    /// This threshold is empirical (sweep on the paper traces, see docs/performance.md):
    /// the long-lived branches of the A traces gain 2-2.5x from depth-first order,
    /// while the C traces' short, rapidly synchronising regions get ~10-30%
    /// slower with it even though they do slightly *less* tracker movement.
    /// Overridable via EGWALKER_DFS_MIN for experiments.
    nonisolated(unsafe) static var defaultDfsMinEntries: Int = {
        if let s = getenv("EGWALKER_DFS_MIN"), let v = Int(String(cString: s)) { return v }
        return 64
    }()

    var dfsMinEntries = Walker.defaultDfsMinEntries

    /// When true, the tree validates every invariant after each step (tests only).
    var debugChecks = false

    init(oplog: OpLog, doc: GapBuffer) {
        self.oplog = oplog
        self.doc = doc
    }

    deinit {
        delTarget?.deallocate()
        diffQueue.deallocate()
        oneParent.deallocate()
    }

    // MARK: - Raw oplog access

    @inline(__always) private func entryIndex(_ v: LV) -> Int {
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) &>> 1
            let e = entries[mid]
            if v < e.version { hi = mid } else if v >= e.vEnd { lo = mid &+ 1 } else { return mid }
        }
        preconditionFailure("Invalid or unknown local version \(v)")
    }

    @inline(__always) private func parents(_ e: CGEntry) -> UnsafeBufferPointer<LV> {
        UnsafeBufferPointer(rebasing: parentPool[e.parentsStart..<(e.parentsStart + Int(e.parentsCount))])
    }

    @inline(__always) private func runIndex(_ lv: LV) -> Int {
        var lo = 0, hi = runs.count
        while lo < hi {
            let mid = (lo + hi) &>> 1
            let r = runs[mid]
            if lv < r.lvStart { hi = mid } else if lv >= r.lvEnd { lo = mid &+ 1 } else { return mid }
        }
        preconditionFailure("Unknown LV \(lv)")
    }

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
            var j = 0
            while j < frontier.count {
                if ps.contains(frontier[j]) { frontier.swapAt(j, frontier.count - 1); frontier.removeLast() }
                else { j += 1 }
            }
            frontier.append(e.vEnd - 1)
            var ce = e.version
            if frontier.count == 1 {
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
        let (critEnd, maxRegion) = Self.plan(oplog.cg)
        oplog.cg.entries.withUnsafeBufferPointer { e in
        oplog.cg.parentPool.withUnsafeBufferPointer { p in
        oplog.runs.withUnsafeBufferPointer { r in
        oplog.content.withUnsafeBufferPointer { c in
            entries = e; parentPool = p; runs = r; content = c
            defer {
                entries = .init(start: nil, count: 0); parentPool = .init(start: nil, count: 0)
                runs = .init(start: nil, count: 0); content = .init(start: nil, count: 0)
            }
            walk(critEnd: critEnd, maxRegion: maxRegion)
        }}}}
        if tracking { stopTracking() }
    }

    private func walk(critEnd: [LV], maxRegion: Int) {
        let n = entries.count
        var ffVersion: LV = -1  // the doc's version while fast-forwarding (-1: root)
        var i = 0
        while i < n {
            let e = entries[i]
            let ce = critEnd[i]
            if ce > e.version {
                // Critical prefix: the document is exactly at this event's parent
                // version, so its positions are valid as-is.
                if tracking { stopTracking() }
                fastForward(e.version, ce)
                ffVersion = ce - 1
            }
            if ce < e.vEnd {
                // A concurrent region: this entry's tail plus every following
                // entry up to the next one that starts with a critical event.
                var j = i + 1
                while j < n && critEnd[j] == entries[j].version { j += 1 }
                if !tracking { startTracking(at: ce, version: ffVersion, capacity: maxRegion) }
                if j - i >= dfsMinEntries {
                    processRegion(firstEntry: i, firstStart: ce, endEntry: j)
                } else {
                    for k in i..<j {
                        let ek = entries[k]
                        if k == i && ce > ek.version {
                            oneParent.pointee = ce - 1
                            trackedApply(ce, ek.vEnd, parents: UnsafeBufferPointer(start: oneParent, count: 1))
                        } else {
                            trackedApply(ek.version, ek.vEnd, parents: parents(ek))
                        }
                    }
                }
                i = j
            } else {
                i += 1
            }
        }
    }

    // MARK: - Incremental merge

    /// Brings `doc` (currently at `branchVersion`) up to `mergeVersion`.
    ///
    /// This is Eg-walker's real-world operation: you have a document open, new
    /// events arrive. Only events after the latest common ancestor of the two
    /// versions matter:
    /// - *conflict* events (already in the document, but concurrent with new
    ///   ones) are replayed into the CRDT only, to rebuild the state the new
    ///   events must be transformed against;
    /// - *new* events are then applied through the CRDT to the document.
    /// Placeholders stand in for the document at the common ancestor. Like the
    /// reference implementation we use `max(branchVersion) + 1` of them, an upper
    /// bound on its length; spare ones sit at the end and never move text.
    func merge(branchVersion: [LV], mergeVersion: [LV]) -> [LV] {
        let cg = oplog.cg
        var newOps: [LVRange] = [], conflictOps: [LVRange] = []
        let common = cg.findConflicting(branchVersion, mergeVersion) { span, flag in
            if flag == .b {
                if let last = newOps.last, last.start == span.end { newOps[newOps.count - 1].start = span.start }
                else { newOps.append(span) }
            } else {
                if let last = conflictOps.last, last.start == span.end { conflictOps[conflictOps.count - 1].start = span.start }
                else { conflictOps.append(span) }
            }
        }
        let resultVersion = cg.findDominators(branchVersion + mergeVersion)
        if newOps.isEmpty { return resultVersion }
        newOps.reverse(); conflictOps.reverse()
        let base = Swift.min(conflictOps.first?.start ?? Int.max, newOps[0].start)

        oplog.cg.entries.withUnsafeBufferPointer { e in
        oplog.cg.parentPool.withUnsafeBufferPointer { p in
        oplog.runs.withUnsafeBufferPointer { r in
        oplog.content.withUnsafeBufferPointer { c in
            entries = e; parentPool = p; runs = r; content = c
            defer {
                entries = .init(start: nil, count: 0); parentPool = .init(start: nil, count: 0)
                runs = .init(start: nil, count: 0); content = .init(start: nil, count: 0)
            }
            startTracking(at: base, versionSet: common, capacity: oplog.count - base,
                          placeholders: (branchVersion.max() ?? -1) + 1)
            docEnabled = false
            for range in conflictOps { applyRange(range) }
            docEnabled = true
            for range in newOps { applyRange(range) }
        }}}}
        stopTracking()
        return resultVersion
    }

    /// Applies every event in `range` through the tracker, entry by entry.
    private func applyRange(_ range: LVRange) {
        var i = entryIndex(range.start)
        while i < entries.count && entries[i].version < range.end {
            let e = entries[i]
            let s = Swift.max(range.start, e.version), t = Swift.min(range.end, e.vEnd)
            if s == e.version {
                trackedApply(s, t, parents: parents(e))
            } else {
                oneParent.pointee = s - 1
                trackedApply(s, t, parents: UnsafeBufferPointer(start: oneParent, count: 1))
            }
            i += 1
        }
    }

    // MARK: - Traversal order

    /// Applies the entries `[firstEntry, endEntry)` (the first one starting at
    /// `firstStart`) in a topological order that keeps tracker movement small.
    ///
    /// Any topological order yields the same document, but the cost differs a
    /// lot. Moving the tracker between versions costs one retreat/advance per
    /// event in their symmetric difference. Picture a fork with a small branch S
    /// and a large branch L that merge later:
    ///   S first: retreat S when switching to L, advance S at the merge: 2·|S|
    ///   L first: retreat L, advance L at the merge:                   2·|L|
    /// So: depth-first, smallest subtree first (the same idea as diamond-types'
    /// planner). On the A2 trace this cuts retreat+advance work from 6.0M to 2.4M.
    private func processRegion(firstEntry: Int, firstStart: LV, endEntry: Int) {
        let m = endEntry - firstEntry
        let firstIsPartial = firstStart > entries[firstEntry].version
        @inline(__always) func start(_ k: Int) -> LV { k == 0 ? firstStart : entries[firstEntry + k].version }
        @inline(__always) func end(_ k: Int) -> LV { entries[firstEntry + k].vEnd }
        @inline(__always) func parentsOf(_ k: Int) -> UnsafeBufferPointer<LV> {
            if k == 0 && firstIsPartial {
                oneParent.pointee = firstStart - 1
                return UnsafeBufferPointer(start: oneParent, count: 1)
            }
            return parents(entries[firstEntry + k])
        }
        /// Region-local index of the entry containing `v` (v >= firstStart).
        @inline(__always) func entryOf(_ v: LV) -> Int {
            var lo = 0, hi = m
            while lo < hi {
                let mid = (lo + hi) >> 1
                if v >= end(mid) { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        // Child lists (CSR layout) and in-degrees, at entry granularity.
        var indeg = [Int32](repeating: 0, count: m)
        var childStart = [Int](repeating: 0, count: m + 1)
        for k in 0..<m {
            for p in parentsOf(k) where p >= firstStart {
                childStart[entryOf(p) + 1] += 1
                indeg[k] += 1
            }
        }
        for k in 0..<m { childStart[k + 1] += childStart[k] }
        var children = [Int32](repeating: 0, count: childStart[m])
        var fill = childStart
        for k in 0..<m {
            for p in parentsOf(k) where p >= firstStart {
                let pe = entryOf(p)
                children[fill[pe]] = Int32(k)
                fill[pe] += 1
            }
        }

        // Subtree cost: events in this entry plus (over-)counted descendants.
        // Children always come after parents in LV order, so one reverse pass works.
        var subtree = [Int](repeating: 0, count: m)
        var k = m - 1
        while k >= 0 {
            var c = end(k) - start(k)
            for ci in childStart[k]..<childStart[k + 1] {
                c = Swift.min(c &+ subtree[Int(children[ci])], Int.max / 4)
            }
            subtree[k] = c
            k -= 1
        }

        // Depth-first; when several entries become ready, the smallest subtree
        // goes on top of the stack (visited first).
        var stack: [Int32] = []
        var ready: [Int32] = []
        for k in 0..<m where indeg[k] == 0 { ready.append(Int32(k)) }
        ready.sort { subtree[Int($0)] > subtree[Int($1)] }
        stack.append(contentsOf: ready)

        while let top = stack.popLast() {
            let k = Int(top)
            trackedApply(start(k), end(k), parents: parentsOf(k))
            ready.removeAll(keepingCapacity: true)
            for ci in childStart[k]..<childStart[k + 1] {
                let c = Int(children[ci])
                indeg[c] -= 1
                if indeg[c] == 0 { ready.append(Int32(c)) }
            }
            if ready.count > 1 { ready.sort { subtree[Int($0)] > subtree[Int($1)] } }
            stack.append(contentsOf: ready)
        }
    }

    // MARK: - Fast-forward

    private func fastForward(_ start: LV, _ end: LV) {
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
        var ri = runIndex(start)
        var lv = start
        while lv < end {
            let run = runs[ri]
            let b = Swift.min(end, run.lvEnd)
            body(run, lv, b)
            lv = b
            ri += 1
        }
    }

    // MARK: - Tracking

    private func startTracking(at base: LV, version: LV, capacity: Int) {
        startTracking(at: base, versionSet: version >= 0 ? [version] : [], capacity: capacity, placeholders: doc.count)
    }

    /// Starts a CRDT session whose events all have LV >= `base`, at `versionSet`,
    /// with `placeholders` items standing in for the document at that version.
    private func startTracking(at base: LV, versionSet: [LV], capacity: Int, placeholders: Int) {
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
        if placeholders > 0 {
            t.insertSpan(Span(lv: placeholderBase, originLeft: -1, rightParent: -1, len: Int32(placeholders),
                              cur: ItemState.inserted, endDeleted: false), leaf: t.firstLeaf, at: 0)
        }
        curVersion.removeAll()
        for v in versionSet { curVersion.append(v) }
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
    private func trackedApply(_ start: LV, _ end: LV, parents: UnsafeBufferPointer<LV>) {
        stats.tracked += end - start
        if !curVersion.equals(parents) { moveTracker(to: parents) }
        forEachOpPiece(start, end) { run, a, b in
            switch run.kind {
            case .insert:
                let from = run.contentStart + (a - run.lvStart)
                trackedInsert(lv: a, count: b - a, pos: run.pos(at: a - run.lvStart),
                              UnsafeBufferPointer(rebasing: content[from..<(from + b - a)]))
            case .delete:
                if run.fwd {
                    trackedDelete(lv: a, count: b - a, pos: run.pos, reversed: false)
                } else {
                    trackedDelete(lv: a, count: b - a, pos: run.pos(at: b - 1 - run.lvStart), reversed: true)
                }
            }
        }
        curVersion.removeAll()
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
    private func moveTracker(to target: UnsafeBufferPointer<LV>) {
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

        for i in 0..<curVersion.count { enq(curVersion[i], fA) }
        for v in target { enq(v, fB) }

        while qCount > numShared {
            qCount -= 1
            var v = q[qCount] >> 2
            var flag = q[qCount] & 3
            if flag == fShared { numShared -= 1 }
            let e = entries[entryIndex(v)]
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
            for p in parents(e) { enq(p, flag) }
        }
        if !pendingRetreat.isEmpty { applyDelta(pendingRetreat, -1) }
        var k = diffAdvance.count - 1
        while k >= 0 { applyDelta(diffAdvance[k], +1); k -= 1 }
    }

    /// Retreats (-1) or advances (+1) every event in `r`.
    @inline(__always) private func encodeTarget(_ lv: LV) -> Int32 {
        isPlaceholder(lv) ? Int32(-(lv - placeholderBase) - 1) : Int32(lv - trackBase)
    }
    @inline(__always) private func decodeTarget(_ v: Int32) -> LV {
        v >= 0 ? trackBase + Int(v) : placeholderBase + Int(-v - 1)
    }

    private func applyDelta(_ r: LVRange, _ delta: Int32) {
        let tree = self.tree!
        if delta < 0 { stats.retreated += r.count } else { stats.advanced += r.count }
        precondition(r.start >= trackBase, "retreat/advance below the tracking base")
        forEachOpPiece(r.start, r.end) { run, a, b in
            switch run.kind {
            case .insert:
                tree.addToCur(lv: a, count: b - a, delta: delta)
            case .delete:
                // Group consecutive targets (ascending or descending) into ranges.
                let dt = delTarget!
                @inline(__always) func target(_ k: Int) -> LV { decodeTarget(dt[k - trackBase]) }
                var i = a
                while i < b {
                    let t0 = target(i)
                    var j = i + 1
                    if j < b && target(j) == t0 + 1 {
                        while j < b && target(j) == t0 + (j - i) { j += 1 }
                        tree.addToCur(lv: t0, count: j - i, delta: delta)
                    } else if j < b && target(j) == t0 - 1 {
                        while j < b && target(j) == t0 - (j - i) { j += 1 }
                        tree.addToCur(lv: t0 - (j - i - 1), count: j - i, delta: delta)
                    } else {
                        tree.addToCur(lv: t0, count: 1, delta: delta)
                    }
                    i = j
                }
            }
        }
    }

    private func trackedInsert(lv: LV, count n: Int, pos: Int, _ text: UnsafeBufferPointer<Unicode.Scalar>) {
        let tree = self.tree!
        var cursor = tree.cursorAfterCurPos(pos)

        // Origin left: the item right before the cursor.
        let originLeft: Int
        if pos == 0 { originLeft = -1 } else {
            originLeft = tree.span(cursor.leaf, cursor.idx).lv + cursor.off - 1
        }

        // Find the first item at/after the cursor that isn't NYI. Fugue's rule:
        // it's our right parent only if it shares our origin-left.
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
                var s = tree.span(leaf, idx)
                nextIsNYI = s.cur == ItemState.notYetInserted
                var found = true
                while s.cur == ItemState.notYetInserted {
                    off = 0
                    if !tree.nextSpan(&leaf, &idx) { found = false; break }
                    s = tree.span(leaf, idx)
                }
                if found {
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
        if docEnabled { doc.insert(text, at: cursor.endPos) }
    }

    /// YjsMod / Fugue integration, at span granularity. See ReferenceWalker.integrate.
    ///
    /// Items after the first in a span always have origin-left = the previous
    /// item, which sits right of our origin-left, so they never stop the scan and
    /// never change `scanning`: the whole span can be stepped over at once.
    private func integrate(lv: LV, originLeft: Int, rightParent: Int, cursor: inout TreeCursor,
                           firstLeaf: Int32, firstIdx: Int) {
        let tree = self.tree!
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
                if orightRank == rightRank && oplog.cg.compareLV(lv, other.lv) < 0 { break }
                scanning = orightRank < rightRank
            }
            if !other.endDeleted { scanEndPos += Int(other.len) }
            if !scanning {
                cursor = TreeCursor(leaf: leaf, idx: idx, off: Int(other.len), endPos: scanEndPos)
            }
            if !tree.nextSpan(&leaf, &idx) { break }
        }
    }

    private func trackedDelete(lv: LV, count n: Int, pos: Int, reversed: Bool) {
        let tree = self.tree!
        let dt = delTarget!
        let c = tree.cursorAtVisible(pos)
        var leaf = c.leaf, idx = c.idx, off = c.off
        var docPos = c.endPos
        var k = 0
        while k < n {
            let s = tree.span(leaf, idx)
            if s.cur != ItemState.inserted {
                if !s.endDeleted { docPos += Int(s.len) - off }
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
                dt[delLV - trackBase] = encodeTarget(targetStart + j)
            }
            if !s.endDeleted && docEnabled { doc.delete(at: docPos, count: m) }
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

/// A tiny set of LVs (a version frontier). Frontiers almost always hold one or two
/// entries, so this avoids allocating for them.
struct SmallVersion {
    private var a: LV = 0, b: LV = 0
    private var overflow: [LV] = []
    private(set) var count = 0

    @inline(__always) mutating func removeAll() { count = 0; if !overflow.isEmpty { overflow.removeAll() } }
    @inline(__always) mutating func append(_ v: LV) {
        switch count {
        case 0: a = v
        case 1: b = v
        default: overflow.append(v)
        }
        count += 1
    }
    @inline(__always) subscript(i: Int) -> LV { i == 0 ? a : (i == 1 ? b : overflow[i - 2]) }
    @inline(__always) func equals(_ p: UnsafeBufferPointer<LV>) -> Bool {
        if p.count != count { return false }
        for i in 0..<count where self[i] != p[i] { return false }
        return true
    }
}

// MARK: - Public API

extension OpLog {
    /// Replays the whole oplog into a document (the optimized walker).
    public func checkout() -> Branch {
        let doc = GapBuffer(capacity: Swift.max(64, count / 8))
        let walker = Walker(oplog: self, doc: doc)
        walker.checkout()
        return Branch(scalars: doc.scalars, version: cg.heads)
    }

    /// Replays the oplog into a `TextDocument` without materialising a String.
    public func checkoutDocument() -> TextDocument {
        let doc = GapBuffer(capacity: Swift.max(64, count / 8))
        let walker = Walker(oplog: self, doc: doc)
        walker.checkout()
        return TextDocument(buffer: doc, version: cg.heads)
    }

    /// Replays the oplog and returns walker statistics alongside the text (for
    /// benchmarks and tests).
    public func checkoutWithStats() -> (text: [Unicode.Scalar], stats: WalkerStats) {
        let doc = GapBuffer(capacity: Swift.max(64, count / 8))
        let walker = Walker(oplog: self, doc: doc)
        walker.checkout()
        let s = walker.stats
        return (doc.scalars, WalkerStats(fastForwarded: s.fastForwarded, tracked: s.tracked,
                                         trackingSessions: s.trackingSessions, maxTrackedItems: s.maxTrackedItems,
                                         peakTreeBytes: s.peakTreeBytes, docBytes: doc.allocatedBytes,
                                         retreated: s.retreated, advanced: s.advanced))
    }

    /// Checkout with full tree validation after every step. Slow; tests only.
    func checkoutValidated(dfsMinEntries: Int? = nil, validate: Bool = true) -> (text: String, stats: Walker.Stats) {
        let doc = GapBuffer(capacity: Swift.max(64, count / 8))
        let walker = Walker(oplog: self, doc: doc)
        walker.debugChecks = validate
        if let d = dfsMinEntries { walker.dfsMinEntries = d }
        walker.checkout()
        return (Branch(scalars: doc.scalars).text, walker.stats)
    }
}

/// A checked-out document: the text produced by replaying an oplog.
///
/// Not thread-safe: `merge` mutates it in place. Confine each document to one
/// thread or actor (it is deliberately not `Sendable`).
public final class TextDocument {
    let buffer: GapBuffer
    public private(set) var version: [LV]
    init(buffer: GapBuffer, version: [LV]) { self.buffer = buffer; self.version = version }

    /// An empty document (version: the root).
    public convenience init() { self.init(buffer: GapBuffer(), version: []) }

    /// Merges everything in `oplog` that this document hasn't seen yet. Only
    /// events concurrent with the new ones are revisited, so the cost depends on
    /// the size of the merge, not the size of the history.
    ///
    /// `oplog` must contain every event this document has already seen (i.e. be
    /// the same oplog, or one it was synced into).
    public func merge(_ oplog: OpLog, upTo mergeVersion: [LV]? = nil) {
        let walker = Walker(oplog: oplog, doc: buffer)
        version = walker.merge(branchVersion: version, mergeVersion: mergeVersion ?? oplog.cg.heads)
    }
    /// Length in Unicode scalars.
    public var count: Int { buffer.count }
    public var scalars: [Unicode.Scalar] { buffer.scalars }
    public var text: String { Branch(scalars: buffer.scalars).text }
}

public struct WalkerStats: Sendable, CustomStringConvertible {
    public var fastForwarded: Int
    public var tracked: Int
    public var trackingSessions: Int
    public var maxTrackedItems: Int
    public var peakTreeBytes: Int
    public var docBytes: Int
    public var retreated: Int
    public var advanced: Int
    public var description: String {
        "ff=\(fastForwarded) tracked=\(tracked) sessions=\(trackingSessions) maxItems=\(maxTrackedItems) treeBytes=\(peakTreeBytes) docBytes=\(docBytes) retreated=\(retreated) advanced=\(advanced)"
    }
}
