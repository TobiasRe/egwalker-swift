# Design decisions

Short records of decisions that aren't obvious from the code. Each has context, the decision,
and its consequences.

## D1. Fugue right-parent rule, matching the TypeScript reference

**Context.** There are several closely related sequence-CRDT rules: Fugue, FugueMax and
YjsMod. The TypeScript reference's comment says FugueMax, but its code uses the Fugue rule:
the right parent is set only if the next item shares the new item's origin-left. diamond-types
uses a YjsMod formulation.

**Decision.** Implement exactly what the TypeScript code does.

**Consequences.** It passes diamond-types' conformance suite and matches diamond-types
byte for byte on all paper traces. If the variants ever differ on some history, we follow the
reference implementation.

## D2. Agents are compared by bytes

**Context.** Swift's `String ==` uses Unicode canonical equivalence: `"ö" == "o\u{308}"`. A real
git history (nodejs) contains one author name in both normalisation forms. Rust and JS treat
them as two agents.

**Decision.** Intern agents by their UTF-8 bytes, and break insert ties by byte-wise
comparison.

**Consequences.** Same results as the other implementations. Users must not rely on
normalisation to deduplicate agent names.

## D3. Critical versions computed up front, not discovered while walking

**Context.** The paper clears CRDT state at critical versions. They can be detected while
walking or planned in advance.

**Decision.** A single O(entries) planning pass: frontier size, plus a suffix minimum of
parents.

**Consequences.** The walk loop stays simple, and fast-forwarding needs no per-event checks.
The plan costs two `Int` arrays per graph entry, which is negligible.

## D4. Placeholders found by aggregate, not by index

**Context.** A CRDT session starts with one placeholder span representing the existing text.
Concurrent items can reference placeholders as origins.

**Decision.** Placeholder LVs live above `placeholderBase` and are located by descending the
tree on a `ph` aggregate. Real items are located through the dense `leafOf` index.

**Consequences.** Starting a session is O(1) regardless of document size. This is what keeps
the C traces fast and small, since they start thousands of sessions.

## D5. Arena-allocated B-tree with unsafe pointers

**Context.** A class-per-node tree spends its time on ARC and allocation. Swift arrays inside a
class add copy-on-write and exclusivity checks.

**Decision.** Flat, manually managed buffers, `Int32` node indices, O(1) reset.

**Consequences.** Fast and compact, but the compiler no longer guarantees memory safety there.
That is offset by debug bounds asserts, invariant validation after every step in tests,
AddressSanitizer runs, and the reference oracle.

## D6. `@exclusivity(unchecked)` on selected fields

**Context.** Runtime exclusivity checks on class properties cost 10–20% in the hot loop.

**Decision.** Disable them for specific fields of `Walker`, `ItemTree` and `GapBuffer`, each
with a comment. Keep all other runtime checks, including bounds and overflow checks in release.

**Consequences.** These fields must never be accessed re-entrantly or from several threads.
The types are internal and single-threaded by construction.

## D7. No `unsafeFlags`, no `-Ounchecked`

**Decision.** Plain SwiftPM settings.

**Consequences.** The package can be used as a remote dependency (SwiftPM forbids
`unsafeFlags` there). Preconditions stay active in release.

## D8. Gap buffer, not a rope

**Context.** Ropes handle edits at random positions in O(log n). Gap buffers are O(1) for local
edits and O(distance) for jumps.

**Decision.** Gap buffer. A chunked alternative was built and measured. It was slower: memmove
accounted for only ~2% of runtime.

**Consequences.** Simple and fast for real editing patterns. Pathological random-access
workloads would favour a rope.

## D9. Depth-first order only for large regions

See [performance → traversal order](performance.md#traversal-order). The 64-entry threshold is
empirical. Both orders are tested on every region by forcing the threshold in the fuzzer and
the trace tests.

## D10. Preconditions instead of thrown errors

**Decision.** Invalid input traps.

**Consequences.** A corrupted CRDT state could silently diverge replicas, which is worse than
a crash. Apps must validate untrusted remote events before applying them. A throwing,
validating ingestion API is on the [roadmap](roadmap.md).

## D11. Zero dependencies

**Decision.** No swift-collections. The library includes a 50-line heap.

**Consequences.** Trivial to adopt, nothing to keep in version sync. This matters for binary
distribution, for example in XCFrameworks.
