# Mutation testing: triage of survivors

Campaign: 110 randomly sampled mutants (seed 7) out of 869 candidates in the six core
files, gate = fast test subset (~12 s). Raw result: **93 killed, 17 survived (84.5%)**.

Every survivor was triaged by hand.

## Real test gaps (6), all closed

| Mutant | Why it survived | Fix | Verified |
|---|---|---|---|
| `Walker.swift` `reversed: true -> false` (tracked backspace) | No test had a backspace run whose *middle* is the parent of a concurrent branch, so the per-event delete mapping inside a run was never exercised by a partial retreat | `backspaceRunPartiallyRetreated` (3 replicas, 300 seeds) | killed |
| `OpLog.swift` `fwd \|\| del == 1 -> &&` (importer) | Positions of individual deletes in a multi-char delete patch were never checked | `importedDeleteDirection` | killed |
| `CausalGraph.swift` RLE condition in `add` | Un-merged entries give the same text; the test that existed only typed at LV 0, where `+` and `-` coincide | `typingIsRunLengthEncoded` (with a first event by another agent) | killed |
| `OpLog.swift` `last.kind == .insert -> !=` | Un-merged op runs give the same text | `typingIsRunLengthEncoded` | killed |
| `Walker.swift` `idx > 0 -> idx >= 0` | Reading span index -1 through a raw pointer does not trap | `assert` bounds checks in `ItemTree.span`/`spanPtr` (debug only) | killed |
| `CausalGraph.swift` `>= -> >` in `forEachEntry` (reference walker) | Gate gap: the incremental-merge tests weren't in the gate | added them to the gate | killed |

## Performance-only (4): behaviour unchanged, only slower

- `Walker.swift` delete-target grouping (2 mutants): ascending/descending runs are no longer
  grouped, so each item is updated separately.
- `Walker.swift` subtree cost `end - start -> end + start`: a worse traversal order (any
  topological order is correct).
- `GapBuffer.swift` `newWidth > width -> >=`: a no-op "widen" to the same width.

These are guarded by the benchmarks, not the tests.

## Metrics-only (2)

- `ItemTree.swift` `allocatedBytes` arithmetic (2 mutants): only feeds statistics.

## Equivalent (5): cannot change observable behaviour

- `ItemTree.swift` return values of `tryMergeRight` (2): callers either ignore them or only
  re-visit an already-processed span.
- `OpLog.swift` `fwd: true -> false` for single-char deletes in `push` and for insert runs (2):
  normalised (`fwd || len == 1`) or never read for inserts.
- `OpLog.swift` `< Int32.max -> <=`: boundary at 2^31 characters in one run, unreachable.

## Result after triage

- **99 / 110 killed (90.0%).**
- **Every remaining survivor is equivalent, metrics-only or performance-only:
  100% of the behaviour-changing mutants in the sample are now killed.**
- Re-verify with: `Scripts/mutate.py --verify <File.swift:line> ...`
