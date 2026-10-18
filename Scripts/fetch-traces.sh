#!/usr/bin/env bash
# Downloads the Eg-walker paper traces and diamond-types, builds the Rust
# benchmark harness, and exports every .dt trace to JSON with the *original*
# agent names (the paper's anonymised JSON loses them, which matters for
# tie-breaking concurrent inserts — see LEARNING.md).
set -euo pipefail
cd "$(dirname "$0")/.."
VENDOR=${VENDOR:-.vendor}
mkdir -p "$VENDOR" Benchmarks/data

[ -d "$VENDOR/diamond-types" ] || git clone --depth 1 https://github.com/josephg/diamond-types.git "$VENDOR/diamond-types"
if [ ! -d "$VENDOR/egwalker-paper" ]; then
  git clone --depth 1 --filter=blob:none --sparse https://github.com/josephg/egwalker-paper.git "$VENDOR/egwalker-paper"
  (cd "$VENDOR/egwalker-paper" && git sparse-checkout set datasets)
fi
for t in S1 S2 S3 C1 C2 A1 A2; do
  cp "$VENDOR/egwalker-paper/datasets/$t.json" "$VENDOR/egwalker-paper/datasets/$t.dt" Benchmarks/data/
done

# Point the Rust harness at the vendored diamond-types and build it.
sed -i.bak "s#path = \".*diamond-types\"#path = \"../../$VENDOR/diamond-types\"#" Benchmarks/rust-dt-bench/Cargo.toml
(cd Benchmarks/rust-dt-bench && cargo build --release)

for t in S1 S2 S3 C1 C2 A1 A2; do
  Benchmarks/rust-dt-bench/target/release/dt-export "Benchmarks/data/$t.dt" "Benchmarks/data/$t.dt.json"
done
echo "Traces ready in Benchmarks/data"
