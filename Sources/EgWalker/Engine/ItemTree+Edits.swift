extension ItemTree {
    /// Splits spans so that the `n` items starting at (leaf, idx, off) form exactly
    /// one span. Returns its location.
    @inline(__always)
    func isolate(leaf: Int32, idx: Int, off: Int, count n: Int) -> (leaf: Int32, idx: Int) {
        var leaf = leaf, idx = idx
        let s = span(leaf, idx)
        if off + n < Int(s.len) {
            let r = splitSpan(leaf: leaf, idx: idx, off: off + n)
            leaf = r.leaf; idx = r.idx - 1  // the left part sits right before the right part
        }
        if off > 0 {
            let r = splitSpan(leaf: leaf, idx: idx, off: off)
            leaf = r.leaf; idx = r.idx
        }
        return (leaf, idx)
    }

    /// Merges the span at (leaf, idx) with both neighbours where possible.
    @inline(__always)
    func coalesce(leaf: Int32, idx: Int) {
        tryMergeRight(leaf: leaf, idx: idx)
        if idx > 0 { tryMergeRight(leaf: leaf, idx: idx - 1) }
    }

    /// Adds `delta` to the current state of `count` items with consecutive LVs
    /// starting at `lv`. This is how the walker retreats (-1) and advances (+1)
    /// events: an insert moves NYI <-> Inserted, a delete moves Inserted <-> Deleted.
    func addToCur(lv: Int, count: Int, delta: Int32) {
        var lv = lv
        var remaining = count
        while remaining > 0 {
            let f = find(lv)
            let s = span(f.leaf, f.idx)
            let n = Swift.min(remaining, Int(s.len) - f.off)
            let loc = isolate(leaf: f.leaf, idx: f.idx, off: f.off, count: n)
            modifySpan(leaf: loc.leaf, idx: loc.idx) { $0.cur += delta }
            precondition(span(loc.leaf, loc.idx).cur >= ItemState.notYetInserted, "item state underflow")
            coalesce(leaf: loc.leaf, idx: loc.idx)
            lv += n
            remaining -= n
        }
    }
}
