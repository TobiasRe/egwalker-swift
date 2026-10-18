/// A local version: the index of an event in *this replica's* oplog.
///
/// Every event has a globally unique ID `(agent, seq)`, but those are expensive to
/// compare and store. Locally we number events 0, 1, 2, ... in the order we learned
/// about them. Because an event is only ever added after all of its parents, this
/// numbering is always a *topological sort* of the event graph — a property the
/// whole algorithm leans on.
public typealias LV = Int

/// A half-open range `[start, end)` of local versions.
public struct LVRange: Hashable, Sendable, CustomStringConvertible {
    public var start: LV
    public var end: LV
    public init(_ start: LV, _ end: LV) { self.start = start; self.end = end }
    public var count: Int { end - start }
    public var isEmpty: Bool { start >= end }
    public var description: String { "[\(start)..<\(end))" }
}

/// A globally unique event ID.
public struct RawVersion: Hashable, Sendable, CustomStringConvertible {
    public var agent: String
    public var seq: Int
    public init(_ agent: String, _ seq: Int) { self.agent = agent; self.seq = seq }
    public var description: String { "(\(agent),\(seq))" }
}

/// Which side(s) of a two-way graph comparison an event belongs to.
public enum DiffFlag: UInt8, Sendable { case a = 0, b = 1, shared = 2 }

typealias AgentID = Int32

/// One run-length encoded entry of the causal graph.
///
/// A run `[version, vEnd)` contains events by the same agent with consecutive
/// sequence numbers, where every event (except the first) has exactly one parent:
/// the event right before it. Typing a word produces one entry, not one per key.

struct CGEntry: Sendable {
    var version: LV
    var vEnd: LV
    var agent: AgentID
    var seq: Int
    /// Parents of the *first* event of the run. Sorted ascending.
    var parents: [LV]
}

/// Per agent: which sequence numbers map to which local versions.

struct ClientEntry: Sendable {
    var seq: Int
    var seqEnd: Int
    var version: LV
}

/// The causal graph (a.k.a. event graph): which events exist, who made them, and
/// which events each one causally depends on. It stores no operations — just the
/// shape of history. This is a port of `causal-graph.ts` from Joseph Gentle's
/// reference implementation, with the same run-length encoding.
public struct CausalGraph: Sendable {
    /// The current frontier: the set of events nothing else depends on (yet).
    public internal(set) var heads: [LV] = []

    var entries: ContiguousArray<CGEntry> = []
    var agentNames: [String] = []
    /// UTF-8 bytes of each agent name, cached for fast byte-wise comparisons.
    var agentBytes: [[UInt8]] = []
    /// Keyed by UTF-8 bytes, NOT by String: Swift String equality uses Unicode
    /// canonical equivalence, so "ö" (U+00F6) == "o\u{308}". Other implementations
    /// treat those as two different agents, and so must we.
    var agentIDs: [[UInt8]: AgentID] = [:]
    var clientEntries: [[ClientEntry]] = []

    public init() {}

    /// The local version the next new event will get.
    public var nextLV: LV { entries.last?.vEnd ?? 0 }

    /// Number of run-length encoded entries (a measure of how concurrent history is).
    public var entryCount: Int { entries.count }

    // MARK: Agents

    mutating func agentID(_ name: String) -> AgentID {
        let bytes = Array(name.utf8)
        if let id = agentIDs[bytes] { return id }
        let id = AgentID(agentNames.count)
        agentIDs[bytes] = id
        agentNames.append(name)
        agentBytes.append(bytes)
        clientEntries.append([])
        return id
    }

    func existingAgentID(_ name: String) -> AgentID? { agentIDs[Array(name.utf8)] }

    public func nextSeq(forAgent name: String) -> Int {
        guard let id = agentIDs[Array(name.utf8)] else { return 0 }
        return clientEntries[Int(id)].last?.seqEnd ?? 0
    }

    // MARK: Adding events

    /// Adds the events `(agent, seqStart..<seqEnd)` with the given parents (for the
    /// first event). Events we already know are skipped. Returns the newly assigned
    /// LV range, or nil if every event was already known.
    @discardableResult
    public mutating func add(agent name: String, seqStart: Int, seqEnd: Int, parents: [LV]) -> LVRange? {
        precondition(seqEnd > seqStart, "empty span")
        let agent = agentID(name)
        var seqStart = seqStart
        var parents = parents
        let version = nextLV

        // Trim off any prefix we already have.
        while let existing = findClientEntryTrimmed(agent, seqStart) {
            if existing.seqEnd >= seqEnd { return nil }
            seqStart = existing.seqEnd
            parents = [existing.version + (existing.seqEnd - existing.seq) - 1]
        }

        let vEnd = version + (seqEnd - seqStart)
        parents.sort()
        let entry = CGEntry(version: version, vEnd: vEnd, agent: agent, seq: seqStart, parents: parents)

        // Try to extend the last entry instead of pushing a new one (RLE).
        if var last = entries.last,
           last.vEnd == entry.version, last.agent == agent,
           last.seq + (last.vEnd - last.version) == seqStart,
           parents.count == 1, parents[0] == last.vEnd - 1 {
            last.vEnd = vEnd
            entries[entries.count - 1] = last
        } else {
            entries.append(entry)
        }

        insertClientEntry(agent, ClientEntry(seq: seqStart, seqEnd: seqEnd, version: version))
        heads = Self.advanceFrontier(heads, vLast: vEnd - 1, parents: parents)
        return LVRange(version, vEnd)
    }

    /// Adds events whose parents are given as raw IDs (as received over the network).
    @discardableResult
    public mutating func addRaw(_ id: RawVersion, len: Int = 1, parents: [RawVersion]) -> LVRange? {
        let lvParents = parents.map { rawToLV($0)! }
        return add(agent: id.agent, seqStart: id.seq, seqEnd: id.seq + len, parents: lvParents)
    }

    private mutating func insertClientEntry(_ agent: AgentID, _ ce: ClientEntry) {
        var list = clientEntries[Int(agent)]
        clientEntries[Int(agent)] = []  // Avoid a copy-on-write copy while we mutate.
        defer { clientEntries[Int(agent)] = list }

        func tryAppend(_ i: Int) -> Bool {
            let a = list[i]
            if ce.seq == a.seqEnd && ce.version == a.version + (a.seqEnd - a.seq) {
                list[i].seqEnd = ce.seqEnd
                return true
            }
            return false
        }

        if list.isEmpty || ce.seq >= list[list.count - 1].seq {
            if list.isEmpty || !tryAppend(list.count - 1) { list.append(ce) }
            return
        }
        // Rare: an agent's events arrive out of order. Binary search the slot.
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid].seq < ce.seq { lo = mid + 1 } else { hi = mid }
        }
        precondition(lo == list.count || list[lo].seq != ce.seq, "Invalid state - item already exists")
        if lo == 0 || !tryAppend(lo - 1) { list.insert(ce, at: lo) }
    }

    /// `frontier` minus `parents`, plus `vLast`, sorted.
    
    static func advanceFrontier(_ frontier: [LV], vLast: LV, parents: [LV]) -> [LV] {
        // Fast path: the overwhelmingly common case of a linear history.
        if frontier.count == 1 && parents.count == 1 && frontier[0] == parents[0] { return [vLast] }
        var f = frontier.filter { !parents.contains($0) }
        f.append(vLast)
        f.sort()
        return f
    }

    // MARK: Lookups

    private func findClientEntryTrimmed(_ agent: AgentID, _ seq: Int) -> ClientEntry? {
        let list = clientEntries[Int(agent)]
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let e = list[mid]
            if seq < e.seq { hi = mid } else if seq >= e.seqEnd { lo = mid + 1 } else {
                let offset = seq - e.seq
                return offset == 0 ? e : ClientEntry(seq: seq, seqEnd: e.seqEnd, version: e.version + offset)
            }
        }
        return nil
    }

    /// Index of the entry containing `v`.
    
    func findEntryIndex(_ v: LV) -> Int {
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) &>> 1
            let e = entries[mid]
            if v < e.version { hi = mid } else if v >= e.vEnd { lo = mid + 1 } else { return mid }
        }
        preconditionFailure("Invalid or unknown local version \(v)")
    }

    
    func findEntry(_ v: LV) -> CGEntry { entries[findEntryIndex(v)] }

    /// The parents of a single event.
    public func parents(of v: LV) -> [LV] {
        let e = findEntry(v)
        return v == e.version ? e.parents : [v - 1]
    }

    public func lvToRaw(_ v: LV) -> RawVersion {
        let e = findEntry(v)
        return RawVersion(agentNames[Int(e.agent)], e.seq + (v - e.version))
    }

    func lvToAgentSeq(_ v: LV) -> (AgentID, Int) {
        let e = findEntry(v)
        return (e.agent, e.seq + (v - e.version))
    }

    public func rawToLV(_ raw: RawVersion) -> LV? {
        guard let id = agentIDs[Array(raw.agent.utf8)] else { return nil }
        return findClientEntryTrimmed(id, raw.seq)?.version
    }

    public func contains(_ raw: RawVersion) -> Bool { rawToLV(raw) != nil }

    /// Total order used to break ties between concurrent inserts at the same spot.
    /// Agent names are compared byte-wise (UTF-8), then by sequence number. This
    /// matches the Rust implementation and, for ASCII names, the TS reference.
    
    func compareLV(_ a: LV, _ b: LV) -> Int {
        let (agentA, seqA) = lvToAgentSeq(a)
        let (agentB, seqB) = lvToAgentSeq(b)
        if agentA != agentB {
            let ba = agentBytes[Int(agentA)], bb = agentBytes[Int(agentB)]
            return ba.lexicographicallyPrecedes(bb) ? -1 : 1
        }
        return seqA - seqB
    }

    // MARK: Iteration

    /// Calls `visit(start, end, agent, seq, parents)` for every run of events in
    /// `[vStart, vEnd)`, slicing entries at the boundaries.
    
    func forEachEntry(between vStart: LV, _ vEnd: LV, _ visit: (LV, LV, [LV]) throws -> Void) rethrows {
        if vStart >= vEnd { return }
        var idx = findEntryIndex(vStart)
        while idx < entries.count {
            let e = entries[idx]
            if e.version >= vEnd { break }
            let s = Swift.max(vStart, e.version)
            let t = Swift.min(vEnd, e.vEnd)
            try visit(s, t, s == e.version ? e.parents : [s - 1])
            idx += 1
        }
    }
}

// MARK: - Graph algorithms

extension CausalGraph {
    /// The events in the history of exactly one of two versions.
    ///
    /// Picture the two versions as two sets of events (everything they've "seen").
    /// `aOnly` is A∖B, `bOnly` is B∖A. The walker uses this to move its internal
    /// state from one version to another: retreat what's in aOnly, advance bOnly.
    ///
    /// Algorithm: a max-heap walk backwards from both frontiers. Each popped event is
    /// tagged A, B or Shared; we stop when everything left in the queue is Shared.
    public func diff(_ a: [LV], _ b: [LV]) -> (aOnly: [LVRange], bOnly: [LVRange]) {
        // Fast paths.
        if a == b { return ([], []) }

        var flags: [LV: DiffFlag] = [:]
        var queue = MaxHeap<LV>()
        var numShared = 0

        func enq(_ v: LV, _ flag: DiffFlag) {
            if let current = flags[v] {
                if flag != current && current != .shared {
                    flags[v] = .shared
                    numShared += 1
                }
            } else {
                queue.push(v)
                flags[v] = flag
                if flag == .shared { numShared += 1 }
            }
        }

        for v in a { enq(v, .a) }
        for v in b { enq(v, .b) }

        var aOnly: [LVRange] = [], bOnly: [LVRange] = []

        func markRun(_ start: LV, _ endInclusive: LV, _ flag: DiffFlag) {
            precondition(endInclusive >= start, "end < start")
            if flag == .shared { return }
            // Runs are discovered back-to-front. Merge with the previous run if adjacent.
            if flag == .a {
                if let last = aOnly.last, last.start == endInclusive + 1 { aOnly[aOnly.count - 1].start = start }
                else { aOnly.append(LVRange(start, endInclusive + 1)) }
            } else {
                if let last = bOnly.last, last.start == endInclusive + 1 { bOnly[bOnly.count - 1].start = start }
                else { bOnly.append(LVRange(start, endInclusive + 1)) }
            }
        }

        while queue.count > numShared {
            var v = queue.pop()!
            var flag = flags[v]!
            if flag == .shared { numShared -= 1 }

            let e = findEntry(v)

            // Consume other queued versions inside this same run.
            while let peek = queue.peek, peek >= e.version {
                let v2 = queue.pop()!
                let flag2 = flags[v2]!
                if flag2 == .shared { numShared -= 1 }
                if flag2 != flag {
                    markRun(v2 + 1, v, flag)
                    v = v2
                    flag = .shared
                }
            }

            markRun(e.version, v, flag)
            for p in e.parents { enq(p, flag) }
        }

        aOnly.reverse()
        bOnly.reverse()
        return (aOnly, bOnly)
    }

    /// Is `target` in the history of `frontier`?
    public func versionContains(_ frontier: [LV], _ target: LV) -> Bool {
        if frontier.contains(target) { return true }
        var queue = MaxHeap<LV>()
        for v in frontier where v > target { queue.push(v) }

        while let v = queue.pop() {
            if v == target { return true }
            let e = findEntry(v)
            if e.version <= target { return true }
            while let peek = queue.peek, peek >= e.version { queue.pop() }
            for p in e.parents {
                if p == target { return true }
                if p > target { queue.push(p) }
            }
        }
        return false
    }

    /// The subset of `versions` not dominated by another member (the frontier of
    /// their union), sorted ascending.
    public func findDominators(_ versions: [LV]) -> [LV] {
        if versions.count <= 1 { return versions }
        var result: [LV] = []
        if versions.count == 2 {
            var (v0, v1) = (versions[0], versions[1])
            if v0 == v1 { return [v0] }
            if v0 > v1 { swap(&v0, &v1) }
            return versionContains([v1], v0) ? [v1] : [v0, v1]
        }

        // Encode (version, isInput) as even/odd numbers so ties pop inputs last.
        var queue = MaxHeap<Int>()
        for v in versions { queue.push(v * 2) }
        var inputsRemaining = versions.count

        while inputsRemaining > 0, let vEnc = queue.pop() {
            let isInput = vEnc & 1 == 0
            let v = vEnc >> 1
            if isInput {
                result.append(v)
                inputsRemaining -= 1
            }
            let e = findEntry(v)
            while let peek = queue.peek, peek >= e.version * 2 {
                let v2 = queue.pop()!
                if v2 & 1 == 0 { inputsRemaining -= 1 }
            }
            for p in e.parents { queue.push(p * 2 + 1) }
        }
        // Remove duplicates (the same input twice is only one dominator).
        result.reverse()
        var deduped: [LV] = []
        for v in result where deduped.last != v { deduped.append(v) }
        return deduped
    }

    /// Finds the latest common ancestor of `a` and `b` and reports every event
    /// after it, tagged with which side(s) it belongs to. Spans are visited in
    /// *reverse* order. Returns the common ancestor version.
    ///
    /// This is how a branch knows which already-applied events (the "conflict set")
    /// it must replay to rebuild CRDT state before merging new events.
    public func findConflicting(_ a: [LV], _ b: [LV], visit: (LVRange, DiffFlag) -> Void) -> [LV] {
        struct TimePoint {
            var v: [LV]  // sorted descending
            var flag: DiffFlag
        }
        func point(_ v: [LV], _ flag: DiffFlag) -> TimePoint {
            TimePoint(v: v.count <= 1 ? v : v.sorted(by: >), flag: flag)
        }
        // Order: compare versions element-wise, highest first; then by flag.
        var queue = MaxHeap<TimePoint> { x, y in
            for i in 0..<x.v.count {
                if y.v.count <= i { return false } // x > y
                if x.v[i] != y.v[i] { return x.v[i] < y.v[i] }
            }
            if x.v.count < y.v.count { return true }
            return x.flag.rawValue < y.flag.rawValue
        }

        queue.push(point(a, .a))
        queue.push(point(b, .b))

        while true {
            var tp = queue.pop()!
            var flag = tp.flag
            if tp.v.isEmpty { return [] }

            // Discard duplicates.
            while let peek = queue.peek, peek.v == tp.v {
                if peek.flag != flag { flag = .shared }
                queue.pop()
            }

            if queue.isEmpty { return tp.v.reversed() }

            // A merge point: shatter it.
            if tp.v.count > 1 {
                for i in 1..<tp.v.count { queue.push(TimePoint(v: [tp.v[i]], flag: flag)) }
            }

            let t = tp.v[0]
            let containing = findEntry(t)
            let txnStart = containing.version
            var end = t + 1

            while true {
                guard let peek = queue.peek else { return [end - 1] }
                if peek.v.count >= 1 && peek.v[0] >= txnStart {
                    queue.pop()
                    let peekLast = peek.v[0]
                    if peekLast + 1 < end {
                        visit(LVRange(peekLast + 1, end), flag)
                        end = peekLast + 1
                    }
                    if peek.flag != flag { flag = .shared }
                    if peek.v.count > 1 {
                        for i in 1..<peek.v.count { queue.push(TimePoint(v: [peek.v[i]], flag: peek.flag)) }
                    }
                } else {
                    visit(LVRange(txnStart, end), flag)
                    queue.push(point(containing.parents, flag))
                    break
                }
            }
            tp.v = []
        }
    }
}

// MARK: - Debug / validation

extension CausalGraph {
    /// Structural self-check. Used heavily by the tests.
    public func checkInvariants() {
        var expected: LV = 0
        for e in entries {
            precondition(e.version == expected, "entries must be contiguous")
            precondition(e.vEnd > e.version, "inverted entry")
            for p in e.parents { precondition(p < e.version, "parent must precede child") }
            precondition(e.parents == e.parents.sorted(), "parents must be sorted")
            expected = e.vEnd
        }
        for (agent, list) in clientEntries.enumerated() {
            for i in 0..<list.count {
                precondition(list[i].seqEnd > list[i].seq)
                if i > 0 { precondition(list[i - 1].seqEnd <= list[i].seq, "agent \(agent) seqs overlap") }
            }
        }
    }
}
