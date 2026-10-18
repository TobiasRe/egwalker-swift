# Mutation testing report

- Mutants run: 110 (invalid / non-compiling: 0)
- Killed: 93  Survived: 17
- **Mutation score: 84.5%**

| File | Killed | Survived |
|---|---|---|
| CausalGraph.swift | 16 | 2 |
| GapBuffer.swift | 4 | 1 |
| ItemTree.swift | 26 | 4 |
| Walker.swift | 37 | 5 |
| OpLog.swift | 10 | 5 |

## Survivors

- `OpLog.swift:92` bool true→false: `case .delete: pushDelete(lv: range.start, pos: op.pos, len: 1, fwd: true)`
- `ItemTree.swift:141` arith +→-: `+ nodeCapacity * (Self.nodeCap * (4 + MemoryLayout<Agg>.stride) + 12)`
- `Walker.swift:590` arith -→+: `while j < b && target(j) == t0 + (j - i) { j += 1 }`
- `Walker.swift:473` bool true→false: `trackedDelete(lv: a, count: b - a, pos: run.pos(at: b - 1 - run.lvStart), reversed: true)`
- `OpLog.swift:138` bool true→false: `runs.append(OpRun(lvStart: lv, len: Int32(scalars.count), kind: .insert, fwd: true, pos: pos, contentStart: contentStart))`
- `ItemTree.swift:412` bool false→true: `guard Self.canMerge(a, b) else { return false }`
- `Walker.swift:593` arith -→+: `while j < b && target(j) == t0 - (j - i) { j += 1 }`
- `OpLog.swift:134` rel <→<=: `Int(last.len) + scalars.count < Int(Int32.max) {`
- `ItemTree.swift:142` arith +→-: `+ leafOfCapacity * 4`
- `CausalGraph.swift:281` rel >=→>: `if e.version >= vEnd { break }`
- `CausalGraph.swift:137` arith -→+: `last.seq + (last.vEnd - last.version) == seqStart,`
- `Walker.swift:358` arith -→+: `var c = end(k) - start(k)`
- `Walker.swift:662` rel >→>=: `if idx > 0 && ItemTree.canMerge(tree.span(leaf, idx - 1), newSpan) {`
- `OpLog.swift:116` logic ||→&&: `pushDelete(lv: lv, pos: pos, len: del, fwd: fwd || del == 1)`
- `OpLog.swift:131` rel ==→!=: `if var last = runs.last, last.kind == .insert,`
- `ItemTree.swift:410` bool false→true: `guard idx + 1 < n else { return false }`
- `GapBuffer.swift:89` rel >→>=: `guard newWidth > width else { return }`
