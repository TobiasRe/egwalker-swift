# API guide

The public API is small. It has three main types:

| Type | Kind | Role |
|---|---|---|
| `OpLog` | value type (`struct`, `Sendable`) | The persistent state: event graph plus operations. Edit it, sync it, store it. |
| `TextDocument` | reference type (`class`) | A checked-out document you keep open and update incrementally. |
| `Branch` | value type | A plain snapshot (`scalars`, `version`), returned by `checkout()`. |

```swift
import EgWalker
```

## Editing locally

```swift
var oplog = OpLog()
oplog.insert(agent: "alice", at: 0, "Hello")     // returns the LV range of the new events
oplog.insert(agent: "alice", at: 5, " world")
oplog.delete(agent: "alice", at: 0, len: 1)      // deletes "H"
print(oplog.checkout().text)                     // "ello world"
```

`insert` and `delete` always apply *on top of everything this oplog knows* (its `heads`). The
position must be valid in the document at that version:

- `insert`: `0 ... length`
- `delete`: `pos + len <= length`

The oplog does not check this when you call it, because it doesn't keep the text. An invalid
position traps later, during checkout. Validate against your editor's document first.

## Agents

An agent name identifies a writer. Each replica that writes must use its own name, for example
a per-device UUID. Sequence numbers are assigned automatically per agent. Two replicas writing
under the same name would create conflicting IDs, and that is not supported.

Agent names are compared **byte-wise (UTF-8)**, not with Swift's `String ==`. Swift considers
`"ö"` (U+00F6) and `"o\u{308}"` equal; this library treats them as two different agents, as
other Eg-walker implementations do. This also decides the order of concurrent inserts at the
same position.

## Syncing replicas

The simplest sync is to merge whole oplogs:

```swift
var alice = OpLog(), bob = OpLog()
alice.insert(agent: "alice", at: 0, "Hello")
bob.merge(from: alice)

alice.insert(agent: "alice", at: 5, " world")   // concurrently...
bob.insert(agent: "bob", at: 0, "Oh, ")          // ...on two replicas

alice.merge(from: bob)
bob.merge(from: alice)
assert(alice.checkout().text == bob.checkout().text)  // "Oh, Hello world"
```

`merge(from:)` copies every event the other oplog has and this one doesn't. It is idempotent,
and the order of merges doesn't matter. Its cost is linear in the size of `other`, so it suits
in-process or small syncs. For a network protocol, send individual events instead.

### Event-by-event sync

```swift
// Sender: describe event `lv`.
let id = sender.cg.lvToRaw(lv)                                   // (agent, seq)
let parents = sender.cg.parents(of: lv).map { sender.cg.lvToRaw($0) }
let op = sender.op(at: lv)                                       // kind, pos, content

// Receiver:
let isNew = receiver.push(id: id, parents: parents, op: op)     // false if already known
```

Events must arrive **parents first**. `push` traps if a parent is unknown. To find out what a
peer is missing, compare `latestVersion` (the raw IDs of `heads`) and check unknown IDs with
`cg.contains(_:)`.

## Keeping a document open

`checkout()` replays the whole history. For an editor that stays open while remote edits
arrive, check out once and then merge incrementally:

```swift
let doc = oplog.checkoutDocument()      // TextDocument
// ... later, after oplog.merge(from: remote) or oplog.push(...)
doc.merge(oplog)                        // applies only what's new
print(doc.text, doc.count)
```

`TextDocument.merge` revisits only events after the latest common ancestor of the document's
version and the new version. Its cost depends on the size of the merge, not the length of the
history.

**Requirements:**

- Merge the *same* `OpLog` the document came from, or a later state of it. `doc.version` is
  stored as local versions (LVs), and LVs are only meaningful within one oplog. A different
  oplog instance, even with the same events, may number them differently.
- `TextDocument` is not thread-safe. Confine it to one thread or actor.
- `merge(_:upTo:)` can stop at an intermediate version, for example to replay history step by
  step.

## Positions are Unicode scalars

Every position and length in this API counts **Unicode scalars** (code points):

| Text | Scalars | Grapheme clusters | UTF-16 units |
|---|---|---|---|
| `"e"` | 1 | 1 | 1 |
| `"é"` (precomposed) | 1 | 1 | 1 |
| `"é"` (`e` + U+0301) | 2 | 1 | 2 |
| `"😀"` | 1 | 1 | 2 |
| `"👍🏽"` | 2 | 1 | 4 |

Apple's text APIs (`NSString`, `NSRange`, `UITextView`, `NSTextStorage`) count **UTF-16 code
units**. Convert at the boundary:

```swift
/// UTF-16 offset (from UIKit/AppKit) -> scalar offset (for EgWalker).
func scalarOffset(_ utf16Offset: Int, in s: String) -> Int {
    let idx = String.Index(utf16Offset: utf16Offset, in: s)
    return s.unicodeScalars.distance(from: s.unicodeScalars.startIndex, to: idx)
}

/// Scalar offset -> UTF-16 offset.
func utf16Offset(_ scalarOffset: Int, in s: String) -> Int {
    let idx = s.unicodeScalars.index(s.unicodeScalars.startIndex, offsetBy: scalarOffset)
    return s.utf16.distance(from: s.utf16.startIndex, to: idx)
}
```

Both are O(n) in the offset. For large documents, keep your own index or convert relative to a
recent position.

A concurrent edit can split a grapheme cluster, for example by inserting between a base letter
and its combining accent. That is inherent to character-level CRDTs. Render whatever text
results.

## Importing editing traces

`TraceImport` reads the JSON formats used by the Eg-walker paper and diamond-types:

```swift
let trace = try TraceImport.loadConcurrentTrace(url)   // paper format: S1.json ... A2.json
let oplog = TraceImport.oplog(from: trace)

let export = try TraceImport.loadDTExport(url)         // `dt export` format / our dt-export
let oplog2 = TraceImport.oplog(from: export)
assert(oplog2.checkout().text == export.endContent)
```

The paper's anonymised traces replace agent names with numbers. For traces where concurrent
inserts at the same position are tie-broken by agent name, the original `endContent` cannot be
reproduced from that format. Use `Benchmarks/rust-dt-bench`'s `dt-export` to export a `.dt`
file with its original names ([details](testing.md#the-a2-lesson)).

## Diagnostics

```swift
let (scalars, stats) = oplog.checkoutWithStats()
print(stats)  // ff=… tracked=… sessions=… retreated=… advanced=… treeBytes=… docBytes=…
```

| Field | Meaning |
|---|---|
| `fastForwarded` | events applied directly (critical, no CRDT) |
| `tracked` | events applied through the CRDT |
| `trackingSessions` | how many times CRDT state was built and discarded |
| `retreated` / `advanced` | tracker movement, the main cost on branchy histories |
| `maxTrackedItems`, `peakTreeBytes`, `docBytes` | memory indicators |

`ReferenceWalker.checkout(_:)` is a slow, line-by-line port of the TypeScript reference
implementation. It is public so you can use it as an oracle in your own tests. Don't use it in
production.

## Error handling

The library uses preconditions, not thrown errors. Invalid input (out-of-range positions,
unknown parents, empty inserts) traps, in release builds too. This is deliberate: a silently
corrupted document is worse than a crash. Validate untrusted input, especially remote events,
before passing it in.
