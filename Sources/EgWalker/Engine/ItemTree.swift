/// LVs at or above this value are *placeholders*: stand-ins for characters that
/// existed before the walker started tracking (see `Walker`). Placeholder `k` is
/// the k-th character of the document at that point.
// Placeholder LVs live above every real LV. On 32-bit platforms (WebAssembly's
// wasm32) `1 << 60` would silently shift to 0, so use 2^30 there: that still allows
// ~1 billion events and a ~1 billion character document per CRDT session.
let placeholderBase = Int.bitWidth == 64 ? 1 << 60 : 1 << 30
@inline(__always) func isPlaceholder(_ lv: Int) -> Bool { lv >= placeholderBase }

/// CRDT state values for `Span.cur`.
enum ItemState {
    static let notYetInserted: Int32 = -1
    static let inserted: Int32 = 0
    // >= 1: deleted (n = number of concurrent deletes currently applied)
}

/// A run of CRDT items with consecutive LVs that were typed left-to-right.
///
/// Item `i > 0` of a run always has `originLeft = lv + i - 1` and no right parent,
/// so a run only stores the origins of its first item. A 10 000 character paste is
/// one `Span`, not 10 000 items.
struct Span {
    var lv: Int
    /// Origin left of the first item (-1 = document start).
    var originLeft: Int
    /// Fugue right parent of the first item (-1 = none).
    var rightParent: Int
    var len: Int32
    /// State at the walker's current version: -1 NYI, 0 inserted, n>=1 deleted.
    var cur: Int32
    /// True once any applied event deleted this item (the "end" state).
    var endDeleted: Bool

    @inline(__always) var lvEnd: Int { lv + Int(len) }
    @inline(__always) var isPlaceholderSpan: Bool { isPlaceholder(lv) }

    /// Origin-left of the item at `off`. Placeholders behave like the TS reference:
    /// every placeholder item has origin-left -1.
    @inline(__always) func originLeft(at off: Int) -> Int {
        if isPlaceholderSpan { return -1 }
        return off == 0 ? originLeft : lv + off - 1
    }
}

/// Aggregated widths for a subtree.
struct Agg {
    var cur: Int32 = 0    // items visible at the current version
    var end: Int32 = 0    // items visible in the end state (= document length)
    var items: Int32 = 0  // all items
    var ph: Int32 = 0     // placeholder items

    @inline(__always) init() {}
    @inline(__always) init(_ s: Span) {
        cur = s.cur == ItemState.inserted ? s.len : 0
        end = s.endDeleted ? 0 : s.len
        items = s.len
        ph = s.isPlaceholderSpan ? s.len : 0
    }
    @inline(__always) static func += (a: inout Agg, b: Agg) {
        a.cur &+= b.cur; a.end &+= b.end; a.items &+= b.items; a.ph &+= b.ph
    }
    @inline(__always) static func -= (a: inout Agg, b: Agg) {
        a.cur &-= b.cur; a.end &-= b.end; a.items &-= b.items; a.ph &-= b.ph
    }
    @inline(__always) static func - (a: Agg, b: Agg) -> Agg { var r = a; r -= b; return r }
    var isZero: Bool { cur == 0 && end == 0 && items == 0 && ph == 0 }
}

/// A position in the tree: span `idx` in `leaf`, `off` items into that span.
struct TreeCursor {
    var leaf: Int32
    var idx: Int
    var off: Int
    /// Number of end-state-visible items before this position (= document offset).
    var endPos: Int
}

/// The walker's CRDT state: all items in document order, in a B-tree.
///
/// Each internal node stores, per child, the aggregated widths (`Agg`) so we can
/// find "the 37th visible character at the current version" in O(log n), and
/// compute where an item sits in the document in O(log n).
///
/// Memory layout: flat, manually managed arrays (an arena). Nodes refer to each
/// other by Int32 index, not by object reference. That means no ARC traffic, no
/// per-node allocation, and clearing the tree is O(1). The price is unsafe
/// pointers, which is why the test suite runs this under AddressSanitizer and
/// cross-checks it against the reference implementation.
final class ItemTree {
    static let leafCap = 32
    static let nodeCap = 16

    // Leaves
    @exclusivity(unchecked) private(set) var spans: UnsafeMutablePointer<Span>
    @exclusivity(unchecked) private(set) var leafLen: UnsafeMutablePointer<Int32>
    @exclusivity(unchecked) private var leafParent: UnsafeMutablePointer<Int32>
    @exclusivity(unchecked) private(set) var leafNext: UnsafeMutablePointer<Int32>
    @exclusivity(unchecked) private var leafCapacity: Int
    @exclusivity(unchecked) private(set) var leafCount: Int = 0

    // Internal nodes
    @exclusivity(unchecked) private var children: UnsafeMutablePointer<Int32>
    @exclusivity(unchecked) private var childAgg: UnsafeMutablePointer<Agg>
    @exclusivity(unchecked) private var nodeLen: UnsafeMutablePointer<Int32>
    @exclusivity(unchecked) private var nodeParent: UnsafeMutablePointer<Int32>
    @exclusivity(unchecked) private var nodeLevel: UnsafeMutablePointer<Int32>  // 1 = children are leaves
    @exclusivity(unchecked) private var nodeCapacity: Int
    @exclusivity(unchecked) private var nodeCount: Int = 0

    @exclusivity(unchecked) private var root: Int32 = 0
    @exclusivity(unchecked) private var height: Int = 0  // 0: root is a leaf
    private(set) var total = Agg()

    /// LV -> leaf, for real (non-placeholder) inserted items. Indexed by `lv - lvBase`.
    @exclusivity(unchecked) private var leafOf: UnsafeMutablePointer<Int32>
    @exclusivity(unchecked) private var leafOfCapacity: Int
    @exclusivity(unchecked) private var lvBase: Int = 0

    init(lvCapacity: Int = 0) {
        leafCapacity = 16
        spans = .allocate(capacity: leafCapacity * Self.leafCap)
        leafLen = .allocate(capacity: leafCapacity)
        leafParent = .allocate(capacity: leafCapacity)
        leafNext = .allocate(capacity: leafCapacity)
        nodeCapacity = 8
        children = .allocate(capacity: nodeCapacity * Self.nodeCap)
        childAgg = .allocate(capacity: nodeCapacity * Self.nodeCap)
        nodeLen = .allocate(capacity: nodeCapacity)
        nodeParent = .allocate(capacity: nodeCapacity)
        nodeLevel = .allocate(capacity: nodeCapacity)
        leafOfCapacity = Swift.max(lvCapacity, 16)
        leafOf = .allocate(capacity: leafOfCapacity)
        reset(lvBase: 0, lvCount: 0)
    }

    deinit {
        spans.deallocate(); leafLen.deallocate(); leafParent.deallocate(); leafNext.deallocate()
        children.deallocate(); childAgg.deallocate(); nodeLen.deallocate(); nodeParent.deallocate()
        nodeLevel.deallocate(); leafOf.deallocate()
    }

    var allocatedBytes: Int {
        leafCapacity * (Self.leafCap * MemoryLayout<Span>.stride + 12)
            + nodeCapacity * (Self.nodeCap * (4 + MemoryLayout<Agg>.stride) + 12)
            + leafOfCapacity * 4
    }

    /// Empties the tree. Real LVs used from now on must be in `lvBase ..< lvBase+lvCount`.
    func reset(lvBase: Int, lvCount: Int) {
        leafCount = 0
        nodeCount = 0
        height = 0
        total = Agg()
        root = allocLeaf()
        leafParent[Int(root)] = -1
        self.lvBase = lvBase
        if lvCount > leafOfCapacity {
            leafOf.deallocate()
            leafOfCapacity = Swift.max(lvCount, leafOfCapacity * 2)
            leafOf = .allocate(capacity: leafOfCapacity)
        }
    }

    // MARK: Allocation

    private func allocLeaf() -> Int32 {
        if leafCount == leafCapacity {
            let newCap = leafCapacity * 2
            spans = grow(spans, leafCapacity * Self.leafCap, newCap * Self.leafCap)
            leafLen = grow(leafLen, leafCapacity, newCap)
            leafParent = grow(leafParent, leafCapacity, newCap)
            leafNext = grow(leafNext, leafCapacity, newCap)
            leafCapacity = newCap
        }
        let l = leafCount
        leafCount += 1
        leafLen[l] = 0
        leafNext[l] = -1
        return Int32(l)
    }

    private func allocNode(level: Int32) -> Int32 {
        if nodeCount == nodeCapacity {
            let newCap = nodeCapacity * 2
            children = grow(children, nodeCapacity * Self.nodeCap, newCap * Self.nodeCap)
            childAgg = grow(childAgg, nodeCapacity * Self.nodeCap, newCap * Self.nodeCap)
            nodeLen = grow(nodeLen, nodeCapacity, newCap)
            nodeParent = grow(nodeParent, nodeCapacity, newCap)
            nodeLevel = grow(nodeLevel, nodeCapacity, newCap)
            nodeCapacity = newCap
        }
        let n = nodeCount
        nodeCount += 1
        nodeLen[n] = 0
        nodeParent[n] = -1
        nodeLevel[n] = level
        return Int32(n)
    }

    private func grow<T>(_ p: UnsafeMutablePointer<T>, _ old: Int, _ new: Int) -> UnsafeMutablePointer<T> {
        let q = UnsafeMutablePointer<T>.allocate(capacity: new)
        memmoveElements(q, p, old)
        p.deallocate()
        return q
    }

    // MARK: Basic accessors

    // Raw-pointer reads don't trap on a bad index; they silently read a
    // neighbour's memory. These asserts make debug builds (the test suite) trap
    // instead. They compile away in release. (Mutation testing found an
    // `idx > 0` -> `idx >= 0` bug that read span -1 and went unnoticed.)
    @inline(__always) func span(_ leaf: Int32, _ idx: Int) -> Span {
        assert(leaf >= 0 && Int(leaf) < leafCount && idx >= 0 && idx < Self.leafCap, "span index out of range")
        return spans[Int(leaf) &* Self.leafCap &+ idx]
    }
    @inline(__always) private func spanPtr(_ leaf: Int32, _ idx: Int) -> UnsafeMutablePointer<Span> {
        assert(leaf >= 0 && Int(leaf) < leafCount && idx >= 0 && idx <= Self.leafCap, "span index out of range")
        return spans + (Int(leaf) &* Self.leafCap &+ idx)
    }
    @inline(__always) func len(_ leaf: Int32) -> Int { Int(leafLen[Int(leaf)]) }

    /// The leftmost leaf (leaf 0 is never split away from the left edge).
    var firstLeaf: Int32 { 0 }

    @inline(__always) private func setLeafOf(_ s: Span, _ leaf: Int32) {
        if s.isPlaceholderSpan { return }
        let start = s.lv - lvBase
        precondition(start >= 0 && start + Int(s.len) <= leafOfCapacity, "LV out of tracked range")
        (leafOf + start).update(repeating: leaf, count: Int(s.len))
    }

    /// Records that items `lv..<lv+count` live in `leaf` (after extending a span).
    func markLeaf(lv: Int, count: Int, leaf: Int32) {
        setLeafOf(Span(lv: lv, originLeft: -1, rightParent: -1, len: Int32(count), cur: 0, endDeleted: false), leaf)
    }

    // MARK: Aggregate maintenance

    private func slot(of child: Int32, in node: Int32) -> Int {
        let base = Int(node) * Self.nodeCap
        for i in 0..<Int(nodeLen[Int(node)]) where children[base + i] == child { return i }
        preconditionFailure("child not found in parent")
    }

    /// Adds `delta` to every ancestor of `leaf` (and the total).
    private func propagate(_ leaf: Int32, _ delta: Agg) {
        if delta.isZero { return }
        total += delta
        var child = leaf
        var node = leafParent[Int(leaf)]
        while node >= 0 {
            let s = slot(of: child, in: node)
            childAgg[Int(node) * Self.nodeCap + s] += delta
            child = node
            node = nodeParent[Int(node)]
        }
    }

    // MARK: Structural edits

    /// Inserts `s` at `idx` in `leaf`. Returns where it ended up (the leaf may split).
    @discardableResult
    func insertSpan(_ s: Span, leaf: Int32, at idx: Int) -> (leaf: Int32, idx: Int) {
        var leaf = leaf
        var idx = idx
        if len(leaf) == Self.leafCap {
            let half = Self.leafCap / 2
            let newLeaf = splitLeaf(leaf, at: half)
            if idx > half { leaf = newLeaf; idx -= half }
        }
        let n = len(leaf)
        let base = spanPtr(leaf, 0)
        memmoveElements(base + idx + 1, base + idx, n - idx)
        (base + idx).pointee = s
        leafLen[Int(leaf)] += 1
        setLeafOf(s, leaf)
        propagate(leaf, Agg(s))
        return (leaf, idx)
    }

    /// Moves spans `[at, len)` of `leaf` into a new leaf right after it.
    private func splitLeaf(_ leaf: Int32, at: Int) -> Int32 {
        let newLeaf = allocLeaf()
        let n = len(leaf)
        let moveCount = n - at
        var moved = Agg()
        for i in at..<n { moved += Agg(span(leaf, i)) }
        memmoveElements(spanPtr(newLeaf, 0), spanPtr(leaf, at), moveCount)
        leafLen[Int(leaf)] = Int32(at)
        leafLen[Int(newLeaf)] = Int32(moveCount)
        for i in 0..<moveCount { setLeafOf(span(newLeaf, i), newLeaf) }
        leafNext[Int(newLeaf)] = leafNext[Int(leaf)]
        leafNext[Int(leaf)] = newLeaf
        insertSibling(after: leaf, child: newLeaf, childIsLeaf: true, moved: moved)
        return newLeaf
    }

    @inline(__always) private func parentOf(_ child: Int32, _ isLeaf: Bool) -> Int32 {
        isLeaf ? leafParent[Int(child)] : nodeParent[Int(child)]
    }

    /// `child` was split; `newChild` (holding `moved` widths) goes right after it.
    /// Precondition: the parent's aggregate for `child` still includes `moved`.
    private func insertSibling(after child: Int32, child newChild: Int32, childIsLeaf: Bool, moved: Agg) {
        var parent = parentOf(child, childIsLeaf)
        if parent < 0 {
            // `child` was the root: grow the tree by one level.
            let newRoot = allocNode(level: Int32(height + 1))
            let base = Int(newRoot) * Self.nodeCap
            children[base] = child
            children[base + 1] = newChild
            childAgg[base] = total - moved
            childAgg[base + 1] = moved
            nodeLen[Int(newRoot)] = 2
            setParent(child, newRoot, childIsLeaf)
            setParent(newChild, newRoot, childIsLeaf)
            root = newRoot
            height += 1
            return
        }

        if Int(nodeLen[Int(parent)]) == Self.nodeCap {
            splitNode(parent)
            parent = parentOf(child, childIsLeaf)
        }

        let node = parent
        let s = slot(of: child, in: node)
        childAgg[Int(node) * Self.nodeCap + s] -= moved

        let base = Int(node) * Self.nodeCap
        let n = Int(nodeLen[Int(node)])
        var i = n
        while i > s + 1 {
            children[base + i] = children[base + i - 1]
            childAgg[base + i] = childAgg[base + i - 1]
            i -= 1
        }
        children[base + s + 1] = newChild
        childAgg[base + s + 1] = moved
        nodeLen[Int(node)] = Int32(n + 1)
        setParent(newChild, node, childIsLeaf)
    }

    /// Moves the upper half of a full internal node into a new sibling.
    private func splitNode(_ node: Int32) {
        let half = Self.nodeCap / 2
        let level = nodeLevel[Int(node)]
        let childIsLeaf = level == 1
        let newNode = allocNode(level: level)
        let srcBase = Int(node) * Self.nodeCap
        let dstBase = Int(newNode) * Self.nodeCap
        var movedNode = Agg()
        for i in half..<Self.nodeCap {
            children[dstBase + i - half] = children[srcBase + i]
            childAgg[dstBase + i - half] = childAgg[srcBase + i]
            movedNode += childAgg[srcBase + i]
            setParent(children[srcBase + i], newNode, childIsLeaf)
        }
        nodeLen[Int(node)] = Int32(half)
        nodeLen[Int(newNode)] = Int32(Self.nodeCap - half)
        insertSibling(after: node, child: newNode, childIsLeaf: false, moved: movedNode)
    }

    @inline(__always) private func setParent(_ child: Int32, _ parent: Int32, _ isLeaf: Bool) {
        if isLeaf { leafParent[Int(child)] = parent } else { nodeParent[Int(child)] = parent }
    }

    /// Splits span `idx` of `leaf` so that a span boundary exists at `off`.
    /// Returns the location of the right half.
    @discardableResult
    func splitSpan(leaf: Int32, idx: Int, off: Int) -> (leaf: Int32, idx: Int) {
        var leaf = leaf, idx = idx
        // Make room first, while every aggregate is still exact.
        if len(leaf) == Self.leafCap {
            let half = Self.leafCap / 2
            let newLeaf = splitLeaf(leaf, at: half)
            if idx >= half { leaf = newLeaf; idx -= half }
        }
        let p = spanPtr(leaf, idx)
        let s = p.pointee
        precondition(off > 0 && off < Int(s.len), "split offset out of range")
        var right = s
        right.lv = s.lv + off
        right.len = s.len - Int32(off)
        right.originLeft = s.lv + off - 1
        right.rightParent = -1
        p.pointee.len = Int32(off)
        // Splitting a span doesn't change any aggregate, so nothing to propagate.
        let n = len(leaf)
        let base = spanPtr(leaf, 0)
        memmoveElements(base + idx + 2, base + idx + 1, n - idx - 1)
        (base + idx + 1).pointee = right
        leafLen[Int(leaf)] += 1
        setLeafOf(right, leaf)
        return (leaf, idx + 1)
    }

    /// Replaces span at (leaf, idx) via `f`, keeping aggregates consistent.
    @inline(__always) func modifySpan(leaf: Int32, idx: Int, _ f: (inout Span) -> Void) {
        let p = spanPtr(leaf, idx)
        let before = Agg(p.pointee)
        f(&p.pointee)
        propagate(leaf, Agg(p.pointee) - before)
    }

    /// Can `b` be appended onto `a` (as one run)?
    @inline(__always) static func canMerge(_ a: Span, _ b: Span) -> Bool {
        guard a.lvEnd == b.lv, a.cur == b.cur, a.endDeleted == b.endDeleted else { return false }
        if a.isPlaceholderSpan { return b.isPlaceholderSpan }
        return !b.isPlaceholderSpan && b.originLeft == a.lvEnd - 1 && b.rightParent == -1
    }

    /// Merges span `idx` with its right neighbour (same leaf) if possible.
    @discardableResult
    func tryMergeRight(leaf: Int32, idx: Int) -> Bool {
        let n = len(leaf)
        guard idx + 1 < n else { return false }
        let a = span(leaf, idx), b = span(leaf, idx + 1)
        guard Self.canMerge(a, b) else { return false }
        spanPtr(leaf, idx).pointee.len += b.len
        let base = spanPtr(leaf, 0)
        memmoveElements(base + idx + 1, base + idx + 2, n - idx - 2)
        leafLen[Int(leaf)] -= 1
        // Aggregates unchanged (same states, same total length).
        return true
    }

    // MARK: Navigation

    /// Advances to the next span (skipping empty leaves). Returns false at the end.
    @inline(__always) func nextSpan(_ leaf: inout Int32, _ idx: inout Int) -> Bool {
        idx += 1
        while idx >= len(leaf) {
            let nx = leafNext[Int(leaf)]
            if nx < 0 { return false }
            leaf = nx
            idx = 0
        }
        return true
    }

    /// Cursor right after the `pos`-th item visible at the current version
    /// (pos == 0: document start).
    func cursorAfterCurPos(_ pos: Int) -> TreeCursor {
        if pos == 0 { return TreeCursor(leaf: firstLeaf, idx: 0, off: 0, endPos: 0) }
        precondition(pos <= Int(total.cur), "Document is not long enough to find targetPos")
        var remaining = Int32(pos)
        var endPos = 0
        var node = root
        var level = height
        while level > 0 {
            let base = Int(node) * Self.nodeCap
            let n = Int(nodeLen[Int(node)])
            var i = 0
            while true {
                let a = childAgg[base + i]
                if remaining <= a.cur || i == n - 1 { break }
                remaining -= a.cur
                endPos += Int(a.end)
                i += 1
            }
            node = children[base + i]
            level -= 1
        }
        let leaf = node
        for i in 0..<len(leaf) {
            let s = span(leaf, i)
            if s.cur == ItemState.inserted {
                if remaining <= s.len {
                    let off = Int(remaining)
                    if !s.endDeleted { endPos += off }
                    return TreeCursor(leaf: leaf, idx: i, off: off, endPos: endPos)
                }
                remaining -= s.len
            }
            if !s.endDeleted { endPos += Int(s.len) }
        }
        preconditionFailure("cursorAfterCurPos: inconsistent aggregates")
    }

    /// Cursor at the `pos`-th (0-based) item visible at the current version.
    func cursorAtVisible(_ pos: Int) -> TreeCursor {
        precondition(pos < Int(total.cur), "delete past end of document")
        var remaining = Int32(pos)
        var endPos = 0
        var node = root
        var level = height
        while level > 0 {
            let base = Int(node) * Self.nodeCap
            var i = 0
            while true {
                let a = childAgg[base + i]
                if remaining < a.cur { break }
                remaining -= a.cur
                endPos += Int(a.end)
                i += 1
            }
            node = children[base + i]
            level -= 1
        }
        let leaf = node
        for i in 0..<len(leaf) {
            let s = span(leaf, i)
            if s.cur == ItemState.inserted {
                if remaining < s.len {
                    let off = Int(remaining)
                    if !s.endDeleted { endPos += off }
                    return TreeCursor(leaf: leaf, idx: i, off: off, endPos: endPos)
                }
                remaining -= s.len
            }
            if !s.endDeleted { endPos += Int(s.len) }
        }
        preconditionFailure("cursorAtVisible: inconsistent aggregates")
    }

    /// Finds the item with the given LV. Returns (leaf, idx, off).
    func find(_ lv: Int) -> (leaf: Int32, idx: Int, off: Int) {
        if isPlaceholder(lv) {
            let r = findPlaceholder(lv - placeholderBase)
            return (r.leaf, r.idx, r.off)
        }
        let leaf = leafOf[lv - lvBase]
        for i in 0..<len(leaf) {
            let s = span(leaf, i)
            if lv >= s.lv && lv < s.lvEnd { return (leaf, i, lv - s.lv) }
        }
        preconditionFailure("LV \(lv) not found in its leaf")
    }

    private func findPlaceholder(_ p: Int) -> (leaf: Int32, idx: Int, off: Int, rank: Int) {
        var remaining = Int32(p)
        var rank = 0
        var node = root
        var level = height
        while level > 0 {
            let base = Int(node) * Self.nodeCap
            var i = 0
            while true {
                let a = childAgg[base + i]
                if remaining < a.ph { break }
                remaining -= a.ph
                rank += Int(a.items)
                i += 1
            }
            node = children[base + i]
            level -= 1
        }
        let leaf = node
        for i in 0..<len(leaf) {
            let s = span(leaf, i)
            if s.isPlaceholderSpan {
                if remaining < s.len { return (leaf, i, Int(remaining), rank + Int(remaining)) }
                remaining -= s.len
            }
            rank += Int(s.len)
        }
        preconditionFailure("placeholder \(p) not found")
    }

    /// Number of items (of any state) before (leaf, idx, off).
    func rank(leaf: Int32, idx: Int, off: Int) -> Int {
        var r = off
        for i in 0..<idx { r += Int(span(leaf, i).len) }
        var child = leaf
        var node = leafParent[Int(leaf)]
        while node >= 0 {
            let base = Int(node) * Self.nodeCap
            var i = 0
            while children[base + i] != child {
                r += Int(childAgg[base + i].items)
                i += 1
            }
            child = node
            node = nodeParent[Int(node)]
        }
        return r
    }

    /// Rank of the item with this LV (-1 stays -1; used for origins).
    func rank(ofLV lv: Int) -> Int {
        if lv == -1 { return -1 }
        if isPlaceholder(lv) { return findPlaceholder(lv - placeholderBase).rank }
        let f = find(lv)
        return rank(leaf: f.leaf, idx: f.idx, off: f.off)
    }

    // MARK: Validation

    /// Recomputes every aggregate and checks every structural invariant.
    func checkInvariants() {
        func checkNode(_ node: Int32, _ level: Int) -> Agg {
            if level == 0 {
                var a = Agg()
                for i in 0..<len(node) {
                    let s = span(node, i)
                    precondition(s.len > 0, "empty span")
                    // Compactness: every edit path coalesces, so two neighbours in a
                    // leaf must never be mergeable. (Catches "correct but bloated"
                    // bugs that output-only tests can't see.)
                    if i > 0 { precondition(!Self.canMerge(span(node, i - 1), s), "uncoalesced neighbours") }
                    precondition(s.cur >= -1, "bad state")
                    if !s.isPlaceholderSpan {
                        for k in 0..<Int(s.len) { precondition(leafOf[s.lv + k - lvBase] == node, "stale leafOf") }
                    }
                    a += Agg(s)
                }
                return a
            }
            var a = Agg()
            let base = Int(node) * Self.nodeCap
            precondition(nodeLevel[Int(node)] == Int32(level), "bad level")
            for i in 0..<Int(nodeLen[Int(node)]) {
                let c = children[base + i]
                let parent = level == 1 ? leafParent[Int(c)] : nodeParent[Int(c)]
                precondition(parent == node, "bad parent pointer")
                let sub = checkNode(c, level - 1)
                let stored = childAgg[base + i]
                precondition(sub.cur == stored.cur && sub.end == stored.end && sub.items == stored.items && sub.ph == stored.ph,
                             "stale aggregate")
                a += sub
            }
            return a
        }
        let t = checkNode(root, height)
        precondition(t.cur == total.cur && t.end == total.end && t.items == total.items && t.ph == total.ph, "stale total")
    }
}
