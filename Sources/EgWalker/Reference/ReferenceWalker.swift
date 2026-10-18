/// A deliberately simple, line-by-line port of Joseph Gentle's TypeScript
/// reference implementation (`eg-walker-reference/src/index.ts`).
///
/// It is slow (O(n²) scans everywhere) and that's fine: its job is to be an
/// *oracle*. The optimized engine is tested against it on millions of random
/// histories. When the two disagree, one of them has a bug — and this one is
/// short enough to verify by reading.
public enum ReferenceWalker {
    enum State {
        static let notYetInserted = -1
        static let inserted = 0
        static let deleted = 1  // or more: the number of concurrent deletes
    }

    struct Item {
        var opId: Int
        /// State at the walker's *current* version. Moves back and forth.
        var curState: Int
        /// State once *everything* is merged. Only ever Inserted -> Deleted.
        var endState: Int
        /// Item immediately to the left when this was inserted (-1 = doc start).
        var originLeft: Int
        /// Fugue's right parent (-1 = doc end / right children).
        var rightParent: Int
    }

    struct EditContext {
        var pool: [Item] = []
        /// Pool indices in document order.
        var items: [Int] = []
        var delTargets: [Int: Int] = [:]
        var itemsByLV: [Int: Int] = [:]
        var curVersion: [LV] = []

        func idx(of opId: Int) -> Int {
            guard let i = items.firstIndex(where: { pool[$0].opId == opId }) else {
                preconditionFailure("Could not find needle in items")
            }
            return i
        }
    }

    static func width(_ s: Int) -> Int { s == State.inserted ? 1 : 0 }

    static func advance1(_ ctx: inout EditContext, _ oplog: OpLog, _ opId: Int) {
        let op = oplog.op(at: opId)
        let target = op.kind == .delete ? ctx.delTargets[opId]! : opId
        let p = ctx.itemsByLV[target]!
        if op.kind == .delete {
            precondition(ctx.pool[p].curState >= State.inserted, "adv Del but item is \(ctx.pool[p].curState)")
            precondition(ctx.pool[p].endState >= State.deleted, "Advance delete with item not deleted in endState")
            ctx.pool[p].curState += 1
        } else {
            precondition(ctx.pool[p].curState == State.notYetInserted, "Advance insert for already inserted item")
            ctx.pool[p].curState = State.inserted
        }
    }

    static func retreat1(_ ctx: inout EditContext, _ oplog: OpLog, _ opId: Int) {
        let op = oplog.op(at: opId)
        let target = op.kind == .delete ? ctx.delTargets[opId]! : opId
        let p = ctx.itemsByLV[target]!
        if op.kind == .delete {
            precondition(ctx.pool[p].curState >= State.deleted, "Retreat delete but item not currently deleted")
            precondition(ctx.pool[p].endState >= State.deleted, "Retreat delete but item not deleted")
        } else {
            precondition(ctx.pool[p].curState == State.inserted, "Retreat insert for item not in inserted state")
        }
        ctx.pool[p].curState -= 1
    }

    /// Returns (index in items, endPos) for the first slot at `targetPos` (curState).
    static func findByCurPos(_ ctx: EditContext, _ targetPos: Int) -> (idx: Int, endPos: Int) {
        var curPos = 0, endPos = 0, i = 0
        while curPos < targetPos {
            precondition(i < ctx.items.count, "Document is not long enough to find targetPos")
            let item = ctx.pool[ctx.items[i]]
            curPos += width(item.curState)
            endPos += width(item.endState)
            i += 1
        }
        return (i, endPos)
    }

    /// The YjsMod / Fugue integration: find where among concurrently inserted
    /// items the new item goes.
    static func integrate(_ ctx: EditContext, _ cg: CausalGraph, _ newItem: Item, _ cursor: inout (idx: Int, endPos: Int)) {
        if cursor.idx >= ctx.items.count || ctx.pool[ctx.items[cursor.idx]].curState != State.notYetInserted { return }

        var scanning = false
        var scanIdx = cursor.idx
        var scanEndPos = cursor.endPos

        let leftIdx = cursor.idx - 1
        let rightIdx = newItem.rightParent == -1 ? ctx.items.count : ctx.idx(of: newItem.rightParent)

        while scanIdx < ctx.items.count {
            let other = ctx.pool[ctx.items[scanIdx]]
            if other.curState != State.notYetInserted { break }
            precondition(other.opId != newItem.rightParent, "invalid state")

            let oleftIdx = other.originLeft == -1 ? -1 : ctx.idx(of: other.originLeft)
            if oleftIdx < leftIdx { break }
            else if oleftIdx == leftIdx {
                let orightIdx = other.rightParent == -1 ? ctx.items.count : ctx.idx(of: other.rightParent)
                if orightIdx == rightIdx && cg.compareLV(newItem.opId, other.opId) < 0 { break }
                else { scanning = orightIdx < rightIdx }
            }

            scanEndPos += width(other.endState)
            scanIdx += 1

            if !scanning {
                cursor.idx = scanIdx
                cursor.endPos = scanEndPos
            }
        }
    }

    static func apply1(_ ctx: inout EditContext, _ snapshot: inout [Unicode.Scalar]?, _ oplog: OpLog, _ opId: Int) {
        let op = oplog.op(at: opId)
        if op.kind == .delete {
            var cursor = findByCurPos(ctx, op.pos)
            while ctx.pool[ctx.items[cursor.idx]].curState != State.inserted {
                cursor.endPos += width(ctx.pool[ctx.items[cursor.idx]].endState)
                cursor.idx += 1
            }
            let p = ctx.items[cursor.idx]
            precondition(ctx.pool[p].curState == State.inserted, "Trying to delete an item which is not currently Inserted")
            if ctx.pool[p].endState == State.inserted {
                snapshot?.remove(at: cursor.endPos)
            }
            ctx.pool[p].curState = State.deleted
            ctx.pool[p].endState = State.deleted
            ctx.delTargets[opId] = ctx.pool[p].opId
        } else {
            var cursor = findByCurPos(ctx, op.pos)
            if cursor.idx > 0 {
                precondition(ctx.pool[ctx.items[cursor.idx - 1]].curState == State.inserted)
            }
            let originLeft = cursor.idx == 0 ? -1 : ctx.pool[ctx.items[cursor.idx - 1]].opId

            var rightParent = -1
            var i = cursor.idx
            while i < ctx.items.count {
                let next = ctx.pool[ctx.items[i]]
                if next.curState != State.notYetInserted {
                    // Fugue (not FugueMax): only a right parent if it shares our left origin.
                    rightParent = next.originLeft == originLeft ? next.opId : -1
                    break
                }
                i += 1
            }

            let newItem = Item(opId: opId, curState: State.inserted, endState: State.inserted,
                               originLeft: originLeft, rightParent: rightParent)
            integrate(ctx, oplog.cg, newItem, &cursor)
            ctx.pool.append(newItem)
            ctx.itemsByLV[opId] = ctx.pool.count - 1
            ctx.items.insert(ctx.pool.count - 1, at: cursor.idx)
            snapshot?.insert(op.content!, at: cursor.endPos)
        }
    }

    static func traverseAndApply(_ ctx: inout EditContext, _ oplog: OpLog, _ snapshot: inout [Unicode.Scalar]?,
                                 _ fromOp: Int, _ toOp: Int) {
        oplog.cg.forEachEntry(between: fromOp, toOp) { start, end, parents in
            let (retreat, advance) = oplog.cg.diff(ctx.curVersion, parents)
            for r in retreat.reversed() {
                var lv = r.end - 1
                while lv >= r.start { retreat1(&ctx, oplog, lv); lv -= 1 }
            }
            for r in advance {
                for lv in r.start..<r.end { advance1(&ctx, oplog, lv) }
            }
            for lv in start..<end { apply1(&ctx, &snapshot, oplog, lv) }
            ctx.curVersion = [end - 1]
        }
    }

    /// Replays the whole oplog into a fresh document.
    public static func checkout(_ oplog: OpLog) -> Branch {
        var ctx = EditContext()
        var snapshot: [Unicode.Scalar]? = []
        traverseAndApply(&ctx, oplog, &snapshot, 0, oplog.count)
        return Branch(scalars: snapshot!, version: oplog.cg.heads)
    }

    /// Merges new events from `oplog` into an existing branch.
    public static func merge(_ branch: inout Branch, _ oplog: OpLog, mergeVersion: [LV]? = nil) {
        let mergeVersion = mergeVersion ?? oplog.cg.heads
        var newOps: [LVRange] = [], conflictOps: [LVRange] = []
        let common = oplog.cg.findConflicting(branch.version, mergeVersion) { span, flag in
            if flag == .b {
                if let last = newOps.last, last.start == span.end { newOps[newOps.count - 1].start = span.start }
                else { newOps.append(span) }
            } else {
                if let last = conflictOps.last, last.start == span.end { conflictOps[conflictOps.count - 1].start = span.start }
                else { conflictOps.append(span) }
            }
        }
        newOps.reverse(); conflictOps.reverse()

        var ctx = EditContext()
        ctx.curVersion = common
        // Placeholder items standing in for the document at the common ancestor.
        let placeholderLength = (branch.version.max() ?? -1) + 1
        let placeholderBase = 1 << 50
        for i in 0..<placeholderLength {
            let item = Item(opId: placeholderBase + i, curState: State.inserted, endState: State.inserted,
                            originLeft: -1, rightParent: -1)
            ctx.pool.append(item)
            ctx.items.append(ctx.pool.count - 1)
            ctx.itemsByLV[item.opId] = ctx.pool.count - 1
        }

        var none: [Unicode.Scalar]? = nil
        for r in conflictOps { traverseAndApply(&ctx, oplog, &none, r.start, r.end) }
        var snapshot: [Unicode.Scalar]? = branch.scalars
        for r in newOps { traverseAndApply(&ctx, oplog, &snapshot, r.start, r.end) }
        branch.scalars = snapshot!
        branch.version = oplog.cg.findDominators(branch.version + mergeVersion)
    }
}

/// A document snapshot at some version.
public struct Branch: Sendable, Equatable {
    public var scalars: [Unicode.Scalar]
    public var version: [LV]

    public init(scalars: [Unicode.Scalar] = [], version: [LV] = []) {
        self.scalars = scalars
        self.version = version
    }

    public var text: String {
        var s = String.UnicodeScalarView()
        s.append(contentsOf: scalars)
        return String(s)
    }
}
