# Architecture

## Module map

```
Sources/EgWalker/
├── CausalGraph/
│   ├── CausalGraph.swift      event graph: RLE entries, agents, diff, dominators, conflicts
│   └── Heap.swift             tiny max-heap used by the graph algorithms
├── OpLog/
│   ├── OpLog.swift            causal graph + RLE operation runs + content; local/remote edits, sync
│   └── TraceImport.swift      JSON importers (paper traces, `dt export`)
├── Reference/
│   └── ReferenceWalker.swift  slow, faithful port of the TypeScript reference (the test oracle)
└── Engine/
    ├── Walker.swift           the optimized walker: planning, fast-forward, tracking, merge
    ├── ItemTree.swift         arena-allocated B-tree of CRDT item spans
    ├── ItemTree+Edits.swift   isolate / coalesce / retreat-advance helpers
    ├── GapBuffer.swift        the document text (adaptive 1/2/4-byte gap buffer)
    └── Memmove.swift          overlap-safe moves for trivial types
Sources/EgWalkerBench/         benchmark harness (JSON output, same shape as the Rust harness)
Benchmarks/rust-dt-bench/      diamond-types harness + `dt-export` (original agent names)
Benchmarks/memtrack/           LD_PRELOAD malloc tracker used for both languages
Scripts/                       fetch traces, benchmark, mutation testing, order simulation
```

## Data structures

### Causal graph (`CausalGraph`)

- `entries: ContiguousArray<CGEntry>`: run-length encoded. One entry covers `[version, vEnd)`,
  events by one agent with consecutive sequence numbers, where every event after the first has
  the previous one as its only parent.
- `CGEntry` is plain old data (no arrays inside). The parents of an entry's first event live in
  a shared `parentPool` and are referenced by `parentsStart`/`parentsCount`. Copying an entry
  therefore needs no reference counting, which matters because the walker reads entries
  millions of times.
- `clientEntries[agent]`: per agent, sorted `(seq, seqEnd) -> LV` runs, used to translate IDs
  to LVs.
- Agents are interned by their UTF-8 bytes (see [decisions](decisions.md#d2-agents-are-compared-by-bytes)).

The graph algorithms (`diff`, `versionContains`, `findDominators`, `findConflicting`) are
ports of `causal-graph.ts`. They all walk backwards in time with a max-heap: pop the highest
LV, replace it with its parents, and stop when the remaining queue entries are shared.

### Operation log (`OpLog`)

- `runs: ContiguousArray<OpRun>`: one run is `len` consecutive events of one kind:
  - insert: characters at `pos, pos+1, …`, text in `content[contentStart…]`
  - forward delete (Delete key): `len` deletes all at `pos`
  - backward delete (Backspace): deletes at `pos+len-1, pos+len-2, …, pos`
- `content: ContiguousArray<Unicode.Scalar>`: all inserted text, in LV order.

Op runs and graph entries are encoded independently. An op run may span agents, and a graph
entry may span op runs.

### CRDT state (`ItemTree`)

The walker's temporary CRDT is a B-tree over **spans**. A span is a run of items with
consecutive LVs that were typed left to right:

```swift
struct Span {
    var lv: Int           // first item's LV (>= placeholderBase: a placeholder)
    var originLeft: Int   // origin-left of the first item (-1 = document start)
    var rightParent: Int  // Fugue right parent of the first item (-1 = none)
    var len: Int32
    var cur: Int32        // -1 not yet inserted, 0 inserted, n >= 1 deleted n times
    var endDeleted: Bool  // deleted in the end state
}
```

Item `i > 0` of a span always has `originLeft = lv + i - 1` and no right parent. Only the first
item needs stored origins, and during integration a whole span can be skipped at once.

Layout:

- **Leaves** hold up to 32 spans. **Internal nodes** hold up to 16 children and, for each child,
  an aggregate `Agg { cur, end, items, ph }`: items visible now, items visible in the end
  state, all items, and placeholder items.
- The aggregates answer, in O(log n): "where is the k-th currently visible item?"
  (`cursorAfterCurPos`, `cursorAtVisible`), "what is this item's index?" (`rank`), and "where is
  placeholder k?". The end-state count before a position is the position in the output text.
- **Arena**: nodes live in flat, manually managed buffers and refer to each other by `Int32`
  index. There is no per-node allocation and no ARC, and `reset()` is O(1). Leaf 0 is always
  the leftmost leaf.
- **LV index**: `leafOf[lv - lvBase]` gives the leaf holding a real item. Placeholders are found
  by descending on the `ph` aggregate instead, so starting a session never writes O(document)
  entries.

Invariants, checked by `checkInvariants()` after every step in tests:

- every stored aggregate equals the recomputed sum of its subtree;
- parent pointers and levels are consistent; `leafOf` is exact for every real item;
- no empty spans; no two neighbouring spans in a leaf that could be merged (compactness).

### Text (`GapBuffer`)

A gap buffer whose element width adapts to the content: 1 byte while all text is Latin-1,
2 bytes once a BMP character appears, 4 bytes for astral characters such as emoji. It widens in
place, grows by 1.5x with `realloc`, and binds memory to the active element type.

## How a checkout runs

`OpLog.checkout()` → `Walker.checkout()`:

### 1. Plan (`Walker.plan`, O(entries))

For every graph entry, compute `critEnd`: events `[version, critEnd)` are critical.

- Condition 1 (everything earlier is an ancestor): track the frontier size while scanning
  entries in LV order. It is 1 exactly when the entry's first event dominates everything before
  it. Within an entry this holds for all events or none.
- Condition 2 (everything later is a descendant): no later entry may have a parent below `x`.
  A suffix minimum over entries' smallest parent gives this in one backwards pass, with a root
  entry (no parents) counting as -1. Within an entry, the qualifying events form a prefix.

Condition 2 relies on parent sets being antichains. If they weren't, we would only miss
optimisation opportunities, never produce wrong output.

### 2. Walk (`Walker.walk`)

For each entry:

- **Critical prefix** → `fastForward`: apply each op run straight to the gap buffer. If a CRDT
  session was active, drop it first.
- **Remainder** → a *concurrent region*: this entry's tail plus all following entries up to the
  next one that starts with a critical event.
  - `startTracking`: reset the tree, insert one placeholder span for the current text, and set
    the tracker version to the last critical event.
  - Apply the region's entries through `trackedApply`: in LV order for small regions, depth-first
    with the smallest subtree first for regions of 64 or more entries (`processRegion`; see
    [performance](performance.md#traversal-order)).

### 3. `trackedApply(start, end, parents)`

1. If the tracker isn't at `parents`, call `moveTracker`. This is an allocation-free version of
   `diff` over a tiny sorted queue. It **retreats** events only in the current version (applied
   immediately, in the descending order they're discovered) and then **advances** events only in
   the target.
2. For each op run piece:
   - **insert** (`trackedInsert`): find the cursor after the pos-th visible item. Origin-left is
     the item before it. The right parent is the next item that is *not* NYI (it may be
     visible or deleted), but only if it shares that origin-left (Fugue rule). If the next item is NYI, there is concurrency, and `integrate`
     scans NYI spans with the YjsMod/Fugue ordering rules. Then insert the span, merging into
     the left neighbour when it continues the same run, and insert the text at the cursor's
     end-state position.
   - **delete** (`trackedDelete`): find the pos-th visible item, isolate the visible items being
     deleted, record each delete's target (`delTarget`, Int32-encoded), mark them deleted, and
     remove from the text whatever was still visible in the end state.
3. The tracker is now at `end - 1`.

Retreat and advance (`applyDelta`) add -1 or +1 to the `cur` state of target items. For inserts
the target is the item itself. For deletes it is the recorded `delTarget`, grouped into
ascending or descending runs. `addToCur` isolates the affected items into their own span,
updates them, and coalesces neighbours again.

## How an incremental merge runs

`TextDocument.merge(oplog)` → `Walker.merge(branchVersion:mergeVersion:)`:

1. `findConflicting(branch, merge)` splits the events after the latest common ancestor into
   **conflict** events (already in the document but concurrent with new ones) and **new**
   events.
2. Start a session at the common ancestor with `max(branch) + 1` placeholders. That is an upper
   bound on the document length there; spare placeholders sit at the end and never move text.
3. Replay conflict events with text output disabled, which rebuilds the CRDT state only.
4. Apply new events with text output enabled.

The result is fuzz-tested against full checkouts after every sync step.

## The reference walker

`ReferenceWalker` is a deliberately naive port of `eg-walker-reference/src/index.ts`. It uses
flat arrays and linear scans, so it is O(n²), with one item per character and no fast-forward.
It exists so the optimized engine can be compared against something short enough to verify by
reading. It also provides an independent `merge` into a `Branch`.

## Safety model

The engine uses unsafe pointers in three places, for measured performance reasons:

- the `ItemTree` arena;
- the gap buffer storage;
- raw views of the oplog's arrays, valid only inside `Walker.checkout()`/`merge()`.

Mitigations:

- bounds `assert`s on the raw span accessors (debug builds);
- full-tree invariant checks after every step in the conformance and fuzz tests;
- the full suite runs clean under AddressSanitizer;
- release builds keep Swift's bounds and overflow checks everywhere else (no `-Ounchecked`).

Several hot class fields use `@exclusivity(unchecked)`. The walker is single-threaded and never
passes those fields `inout` while reading them, so the runtime exclusivity checks can never
fire. They cost 10–20% of runtime.
