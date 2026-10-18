#!/usr/bin/env bash
# Benchmarks EgWalker (Swift) against diamond-types (Rust) on the Eg-walker paper
# traces, on the same machine, interleaving the two implementations so that
# noise (other tenants, thermal throttling) hits both equally.
#
#   Scripts/bench.sh [rounds] [iterations]
#
# Prerequisites: Scripts/fetch-traces.sh (downloads traces, builds the Rust
# harness, exports .dt files with original agent names).
#
# Metrics:
#   time   median wall time of `checkout` / `checkout_tip()` (oplog already loaded)
#   heap   peak heap growth during one checkout, measured identically for both via
#          an LD_PRELOAD malloc tracker (Benchmarks/memtrack). Linux only.
set -euo pipefail
cd "$(dirname "$0")/.."
ROUNDS=${1:-3}
ITERS=${2:-25}
TRACES="S1 S2 S3 C1 C2 A1 A2"
OUT=Benchmarks/results
mkdir -p "$OUT"
RAW="$OUT/raw.jsonl"
: > "$RAW"

swift build -c release --product egwalker-bench >/dev/null
(cd Benchmarks/rust-dt-bench && cargo build --release >/dev/null 2>&1)
(cd Benchmarks/memtrack && gcc -O2 -shared -fPIC -o libmemtrack.so memtrack.c -ldl)
PRELOAD=Benchmarks/memtrack/libmemtrack.so

for r in $(seq 1 "$ROUNDS"); do
  for t in $TRACES; do
    LD_PRELOAD=$PRELOAD .build/release/egwalker-bench "Benchmarks/data/$t.dt.json" "$ITERS" | tail -1 >> "$RAW"
    LD_PRELOAD=$PRELOAD Benchmarks/rust-dt-bench/target/release/dt-bench "Benchmarks/data/$t.dt" "$ITERS" >> "$RAW"
  done
done

python3 - "$RAW" "$OUT/RESULTS.md" <<'EOF'
import json, sys, statistics, platform, subprocess
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
traces = ["S1", "S2", "S3", "C1", "C2", "A1", "A2"]
def agg(impl, t, key):
    v = [r[key] for r in rows if r["impl"] == impl and r["trace"] == t]
    return statistics.median(v) if v else float("nan")
cpu = subprocess.run(["sh", "-c", "grep -m1 'model name' /proc/cpuinfo | cut -d: -f2"], capture_output=True, text=True).stdout.strip()
with open(sys.argv[2], "w") as f:
    f.write(f"# Benchmark results\n\nMachine: {cpu} ({platform.system()})\n\n")
    f.write("Median of per-round medians. Time = checkout of an already-loaded oplog.\n")
    f.write("Heap = peak heap growth during one checkout (same malloc tracker for both).\n\n")
    f.write("| Trace | Ops | Swift ms | Rust ms | Speed (Rust/Swift) | Swift heap | Rust heap | Correct |\n")
    f.write("|---|---|---|---|---|---|---|---|\n")
    for t in traces:
        s, d = agg("egwalker-swift", t, "medianMs"), agg("diamond-types", t, "medianMs")
        sh, dh = agg("egwalker-swift", t, "peakHeapBytes"), agg("diamond-types", t, "peakHeapBytes")
        ops = next(r["ops"] for r in rows if r["trace"] == t)
        ok = all(r.get("correct", True) for r in rows if r["impl"] == "egwalker-swift" and r["trace"] == t)
        f.write(f"| {t} | {ops:,} | {s:.2f} | {d:.2f} | {d/s:.2f}x | {sh/1e6:.2f} MB | {dh/1e6:.2f} MB | {'yes' if ok else 'NO'} |\n")
print(open(sys.argv[2]).read())
EOF
