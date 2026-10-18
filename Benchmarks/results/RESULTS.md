# Benchmark results

Machine: Intel(R) Xeon(R) Processor @ 2.10GHz (Linux)

Median of per-round medians. Time = checkout of an already-loaded oplog.
Heap = peak heap growth during one checkout (same malloc tracker for both).

| Trace | Ops | Swift ms | Rust ms | Speed (Rust/Swift) | Swift heap | Rust heap | Correct |
|---|---|---|---|---|---|---|---|
| S1 | 779,334 | 1.98 | 4.05 | 2.05x | 0.33 MB | 1.39 MB | yes |
| S2 | 1,104,627 | 3.50 | 6.04 | 1.73x | 0.41 MB | 0.88 MB | yes |
| S3 | 2,339,471 | 5.49 | 8.21 | 1.50x | 1.17 MB | 0.86 MB | yes |
| C1 | 651,950 | 74.62 | 105.11 | 1.41x | 1.14 MB | 42.68 MB | yes |
| C2 | 608,150 | 107.30 | 153.55 | 1.43x | 1.63 MB | 50.43 MB | yes |
| A1 | 947,337 | 21.65 | 18.80 | 0.87x | 3.02 MB | 3.16 MB | yes |
| A2 | 697,638 | 53.77 | 50.48 | 0.94x | 6.99 MB | 5.83 MB | yes |
