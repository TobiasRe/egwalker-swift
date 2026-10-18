#!/usr/bin/env python3
"""
Mutation testing for EgWalker.

Mutation testing answers "would my tests notice if this code were wrong?". The
runner makes one small, plausible bug at a time (a *mutant*) — `<` becomes `<=`,
`+= 1` becomes `-= 1`, `&&` becomes `||` — rebuilds, and runs a fast but sharp
test gate. If the tests fail, the mutant is *killed* (good). If they still pass,
it *survived*: either the tests have a blind spot there, or the mutant is
*equivalent* (the change doesn't alter behaviour, e.g. a `<` vs `<=` on a value
that can never be equal). Each survivor must be triaged by a human.

Mutation score = killed / (killed + survived). Mutants that don't compile are
discarded (they tell us nothing about the tests).

This is a deliberately small, project-specific runner (Linux + SPM + Swift
Testing). For a general tool on macOS, see swift-mutation-testing, which uses
SwiftSyntax and "schemata" (all mutants compiled once behind a runtime switch)
to avoid one rebuild per mutant.

Usage:
  Scripts/mutate.py [--limit N] [--seed S] [--files PATTERN] [--out DIR]
"""
import argparse, json, os, random, re, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGETS = [
    "Sources/EgWalker/CausalGraph/CausalGraph.swift",
    "Sources/EgWalker/OpLog/OpLog.swift",
    "Sources/EgWalker/Engine/ItemTree.swift",
    "Sources/EgWalker/Engine/ItemTree+Edits.swift",
    "Sources/EgWalker/Engine/Walker.swift",
    "Sources/EgWalker/Engine/GapBuffer.swift",
]

# The test gate: everything that is fast but has teeth (~12s in debug).
GATE_FILTER = ("conformanceSuite|rawTraces|differentialTwoReplicas|differentialManyReplicas"
               "|dtExported|agentNames|simpleLocalEditing|concurrentInserts")
GATE_ENV = {"EGWALKER_FUZZ_ITERS": "60"}

# (name, regex, replacement). Regexes run on the code part of a line only.
OPERATORS = [
    ("rel <→<=",  r"(?<=\s)<(?=\s)",  "<="),
    ("rel <=→<",  r"(?<=\s)<=(?=\s)", "<"),
    ("rel >→>=",  r"(?<=\s)>(?=\s)",  ">="),
    ("rel >=→>",  r"(?<=\s)>=(?=\s)", ">"),
    ("rel ==→!=", r"(?<=\s)==(?=\s)", "!="),
    ("rel !=→==", r"(?<=\s)!=(?=\s)", "=="),
    ("arith +→-", r"(?<=\s)\+(?=\s)", "-"),
    ("arith -→+", r"(?<=\s)-(?=\s)",  "+"),
    ("assign +=→-=", r"(?<=\s)\+=(?=\s)", "-="),
    ("assign -=→+=", r"(?<=\s)-=(?=\s)", "+="),
    ("off-by-one +1", r"(?<=\s)\+ 1\b", "+ 2"),
    ("off-by-one -1", r"(?<=\s)- 1\b", "- 2"),
    ("logic &&→||", r"(?<=\s)&&(?=\s)", "||"),
    ("logic ||→&&", r"(?<=\s)\|\|(?=\s)", "&&"),
    ("bool true→false", r"\btrue\b", "false"),
    ("bool false→true", r"\bfalse\b", "true"),
    ("negation removed", r"(?<=[\s(])!(?=[a-zA-Z(])", ""),
]

SKIP_LINE = re.compile(r"precondition|assert|preconditionFailure|fatalError|print\(|description|Issue\.|"
                       r"^\s*(///|//|\*)|func .*->|static let|import |@inline|deinit|\"")

def code_part(line):
    i = line.find("//")
    return line if i < 0 else line[:i]

def candidates():
    out = []
    for rel in TARGETS:
        lines = (ROOT / rel).read_text().splitlines(keepends=True)
        for ln, line in enumerate(lines):
            if SKIP_LINE.search(line):
                continue
            code = code_part(line)
            for name, pat, rep in OPERATORS:
                for m in re.finditer(pat, code):
                    # Don't touch `->`, `..<`, shifts or generic brackets.
                    s, e = m.start(), m.end()
                    ctx = code[max(0, s - 2):e + 2]
                    if "->" in ctx or "..<" in ctx or ">>" in ctx or "<<" in ctx:
                        continue
                    out.append({"file": rel, "line": ln + 1, "col": s, "end": e,
                                "op": name, "orig": code[s:e], "rep": rep,
                                "source": line.rstrip("\n")})
    return out

def run(cmd, timeout, env=None):
    e = os.environ.copy()
    if env: e.update(env)
    try:
        p = subprocess.run(cmd, cwd=ROOT, env=e, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=timeout, text=True, errors="replace")
        return p.returncode, p.stdout
    except subprocess.TimeoutExpired as ex:
        return "timeout", (ex.stdout or "") if isinstance(ex.stdout, str) else ""

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=120)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--files", default="")
    ap.add_argument("--out", default=str(ROOT / "Benchmarks" / "mutation"))
    args = ap.parse_args()

    cands = [c for c in candidates() if args.files in c["file"]]
    random.Random(args.seed).shuffle(cands)
    cands = cands[:args.limit]
    outdir = Path(args.out); outdir.mkdir(parents=True, exist_ok=True)
    results_path = outdir / "results.jsonl"
    print(f"{len(candidates())} candidate mutants, running {len(cands)}", flush=True)

    # Baseline: the gate must pass on unmutated code.
    rc, _ = run(["swift", "build", "--build-tests"], 900)
    assert rc == 0, "baseline build failed"
    rc, out = run(["swift", "test", "--skip-build", "--filter", GATE_FILTER], 600, GATE_ENV)
    assert rc == 0, "baseline gate failed:\n" + out[-3000:]

    # Resume: keep results of mutants that were already run.
    done = set()
    if results_path.exists():
        for l in open(results_path):
            r = json.loads(l)
            done.add((r["file"], r["line"], r["col"], r["op"]))
    with open(results_path, "a") as f:
        for i, c in enumerate(cands):
            if (c["file"], c["line"], c["col"], c["op"]) in done:
                continue
            path = ROOT / c["file"]
            original = path.read_text()
            lines = original.splitlines(keepends=True)
            line = lines[c["line"] - 1]
            lines[c["line"] - 1] = line[:c["col"]] + c["rep"] + line[c["end"]:]
            t0 = time.time()
            try:
                path.write_text("".join(lines))
                rc, _ = run(["swift", "build", "--build-tests"], 900)
                if rc != 0:
                    status = "invalid"
                else:
                    rc, out = run(["swift", "test", "--skip-build", "--filter", GATE_FILTER], 300, GATE_ENV)
                    status = "survived" if rc == 0 else ("killed (timeout)" if rc == "timeout" else "killed")
            finally:
                path.write_text(original)
            c["status"] = status
            c["seconds"] = round(time.time() - t0, 1)
            f.write(json.dumps(c) + "\n"); f.flush()
            print(f"[{i+1}/{len(cands)}] {status:16s} {c['file'].split('/')[-1]}:{c['line']} {c['op']}", flush=True)

    # Rebuild clean so the working tree's build matches the sources.
    run(["swift", "build", "--build-tests"], 900)
    report(results_path, outdir / "REPORT.md")

def report(results_path, md_path):
    rs = [json.loads(l) for l in open(results_path)]
    killed = [r for r in rs if r["status"].startswith("killed")]
    surv = [r for r in rs if r["status"] == "survived"]
    inval = [r for r in rs if r["status"] == "invalid"]
    valid = len(killed) + len(surv)
    score = 100.0 * len(killed) / valid if valid else 0
    with open(md_path, "w") as f:
        f.write("# Mutation testing report\n\n")
        f.write(f"- Mutants run: {len(rs)} (invalid / non-compiling: {len(inval)})\n")
        f.write(f"- Killed: {len(killed)}  Survived: {len(surv)}\n")
        f.write(f"- **Mutation score: {score:.1f}%**\n\n")
        by_file = {}
        for r in rs:
            if r["status"] == "invalid": continue
            d = by_file.setdefault(r["file"], [0, 0])
            d[0 if r["status"].startswith("killed") else 1] += 1
        f.write("| File | Killed | Survived |\n|---|---|---|\n")
        for k, (a, b) in sorted(by_file.items()):
            f.write(f"| {k.split('/')[-1]} | {a} | {b} |\n")
        f.write("\n## Survivors\n\n")
        for r in surv:
            f.write(f"- `{r['file'].split('/')[-1]}:{r['line']}` {r['op']}: `{r['source'].strip()}`\n")
    print(open(md_path).read())

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--report":
        out = ROOT / "Benchmarks" / "mutation"
        report(out / "results.jsonl", out / "REPORT.md")
    else:
        main()
