# Performance

## Methodology

- **Baseline:** [diamond-types](https://github.com/josephg/diamond-types), the Rust
  implementation by the Eg-walker authors, built with `lto = true`, `codegen-units = 1`.
- **Workload:** the seven traces from the Eg-walker paper:
  - S1–S3: sequential, one author at a time;
  - C1–C2: concurrent, two or three authors syncing frequently;
  - A1–A2: asynchronous git histories with long-lived branches.
- **Time:** `checkout` of an already-loaded oplog. This is what the paper calls *merge* time:
  `ListOpLog::checkout_tip()` in Rust, `OpLog.checkoutDocument()` in Swift. Parsing is excluded.
  The figure is the median of 25 iterations per round, and the median of 3 rounds.
- **Memory:** peak heap growth during one checkout, relative to the loaded oplog. Both
  harnesses run under the same `LD_PRELOAD` malloc tracker (`Benchmarks/memtrack`), so the
  numbers are measured identically.
- **Fairness:** both run on the same machine, interleaved trace by trace, so noise from
  neighbours on the VM hits both. Swift release builds keep bounds and overflow checks on.
- **Correctness:** the Swift harness compares its output with the trace's expected text on
  every run and reports `correct`. A fast wrong answer doesn't count.

Reproduce:

```bash
Scripts/fetch-traces.sh    # traces, diamond-types, Rust harness, .dt exports
Scripts/bench.sh 3 25      # writes Benchmarks/results/RESULTS.md
```

## Results

Intel Xeon @ 2.1 GHz, 2 vCPUs, Linux, Swift 6.4.1, Rust 1.97.0:

| Trace | Events | Swift | Rust | Rust ÷ Swift | Peak heap Swift | Peak heap Rust |
|---|---|---|---|---|---|---|
| S1 | 779k | 1.98 ms | 4.05 ms | 2.05× | 0.33 MB | 1.39 MB |
| S2 | 1.1M | 3.50 ms | 6.04 ms | 1.73× | 0.41 MB | 0.88 MB |
| S3 | 2.3M | 5.49 ms | 8.21 ms | 1.50× | 1.17 MB | 0.86 MB |
| C1 | 652k | 74.6 ms | 105.1 ms | 1.41× | 1.14 MB | 42.7 MB |
| C2 | 608k | 107.3 ms | 153.6 ms | 1.43× | 1.63 MB | 50.4 MB |
| A1 | 947k | 21.7 ms | 18.8 ms | 0.87× | 3.02 MB | 3.16 MB |
| A2 | 698k | 53.8 ms | 50.5 ms | 0.94× | 6.99 MB | 5.83 MB |

Reading the table:

- **S traces:** no CRDT is ever built; everything is fast-forwarded into the gap buffer.
- **C traces:** CRDT sessions are short and cleared at every critical event, with O(1)
  placeholders. That explains the low memory. We have not investigated why diamond-types'
  peak is much higher on these traces.
- **A traces:** most time goes into retreat/advance on long branches; diamond-types is still
  6–13% faster here. See the [roadmap](roadmap.md).
- These numbers are from x86 Linux. **Apple Silicon has not been measured.** The ratio may
  differ, so measure on your target hardware before quoting them.

## Optimisation log

Every change below was measured, mostly with `valgrind --tool=callgrind` and the interleaved
benchmark. They are listed in the order they were tried, including the ones that failed.

| # | Change | Effect | Lesson |
|---|---|---|---|
| 1 | Parents moved from `[LV]` inside `CGEntry` to a shared pool | diff ~3× faster | A struct holding an array is reference-counted on every copy. Keep hot structs POD. |
| 2 | Allocation-free tracker diff: a sorted `Int` array encoding `lv << 2 \| flag`, instead of `Dictionary` + heap | C1 195 → 150 ms | Hashing and generic tuple metadata cost more than a linear scan over 3 elements. |
| 3 | `@exclusivity(unchecked)` on hot class fields | C1 150 → 71 ms *as logged; not reproducible, see below* | Swift checks exclusivity of class `var`s at runtime. Re-measured on today's code the attribute is worth 1–4%. |
| 4 | Raw buffer pointers to the oplog during a walk | fewer retain/release | `withUnsafeBufferPointer` around the whole walk; nothing escapes. |
| 5 | Span split without aggregate propagation | A2 −15% | A split doesn't change any sum, so nothing needs to propagate. |
| 6 | Greedy "follow the child" traversal order | **0%** | Hypothesis rejected. `Scripts/simulate-order.py` showed why. |
| 7 | Depth-first, smallest subtree first, for regions ≥ 64 entries | A2 120 → 51 ms, A1 42 → 20 ms | Retreat + advance work on A2 fell from 6.0M to 2.4M events. |
| 8 | Chunked text buffer instead of a gap buffer | **worse; reverted** | Callgrind had shown memmove at ~2%. Trust the profile, not intuition. |
| 9 | Gap buffer grows with `realloc` ×1.5 | S1 peak 0.58 → 0.33 MB | `realloc` avoids holding old and new copies at once. |
| 10 | Adaptive 1/2/4-byte text storage | S2 peak 1.66 → 0.41 MB | Most documents only need 1–2 bytes per character. |
| 11 | `Int32` delete targets | A2 peak 8.4 → 7.0 MB | Half the memory for the largest per-event array. |

### Traversal order

Any topological order of events produces the same document, but the cost differs. Moving the
tracker between versions costs one retreat or advance per event in their symmetric difference.
Take a fork with a small branch S and a large branch L that later merge:

- **S first:** retreat S when switching to L, advance S again at the merge. Cost: 2·|S|.
- **L first:** retreat L, advance L at the merge. Cost: 2·|L|.

So visit the smallest subtree first, as diamond-types' planner does. `Scripts/simulate-order.py`
computes both costs for any exported trace without running the engine.

| Trace | LV order | Depth-first, small first |
|---|---|---|
| A1 | 1.92M | 1.44M (engine: 0.59M) |
| A2 | 6.04M | 2.63M (engine: 2.43M) |

The simulation works at entry granularity, so it overestimates.

On the C traces, depth-first order does slightly *less* tracker movement but runs 10–30%
slower. The likely cause is cache locality, which we have not verified. Regions with fewer than
64 entries therefore use LV order. The threshold comes from a sweep on the paper traces; it is
a heuristic, not a model. Override it with `EGWALKER_DFS_MIN` for experiments.

## Exclusivity, re-measured

The optimisation log credits `@exclusivity(unchecked)` with C1 150 → 71 ms. That number came
from a single development measurement and could not be reproduced. Re-measured on the current
code (commit 1b2f6ba) by building the benchmark twice, once as is and once with every
`@exclusivity(unchecked)` attribute removed, run interleaved, 3 rounds × 25 iterations:

| Trace | Unchecked (median) | Checked (median) | Cost of the checks |
|---|---|---|---|
| S1 | 2.0 ms | 2.0 ms | ~0% |
| C1 | 75.1 ms | 78.4 ms | +4% |
| C2 | 111.5 ms | 114.8 ms | +3% |
| A1 | 20.4 ms | 20.5 ms | +1% |
| A2 | 53.1 ms | 53.8 ms | +1% |

Both builds produce correct output on every run. The likely reason the effect shrank is that the
later walker rewrite reads the oplog through raw pointers and local copies, leaving few checked
accesses in the hot loop. That explanation has not been verified. Raw output:
[`Benchmarks/results/exclusivity-ab.txt`](../Benchmarks/results/exclusivity-ab.txt).

## Profiling recipes

```bash
swift build -c release -Xswiftc -g
valgrind --tool=callgrind --callgrind-out-file=cg.out \
  .build/release/egwalker-bench Benchmarks/data/C1.dt.json 1
callgrind_annotate --inclusive=yes cg.out | head -60
```

The harness prints the walker statistics (`fastForwarded`, `tracked`, `retreated`,
`advanced`). Check them first: algorithmic problems show up there before they show up in a
profile.
