#!/usr/bin/env python3
# Simulates the retreat/advance cost of two traversal orders (LV order vs.
# depth-first, smallest subtree first) on a trace exported with dt-export.
# Usage: Scripts/simulate-order.py Benchmarks/data/A2.dt.json
import json, sys, heapq
d = json.load(open(sys.argv[1]))
tx = d['txns']
starts = [t['span'][0] for t in tx]; ends = [t['span'][1] for t in tx]
import bisect
def ent(v): return bisect.bisect_right(starts, v) - 1
n = len(tx); w = [ends[i]-starts[i] for i in range(n)]
par = [sorted(set(ent(p) for p in t['parents'])) for t in tx]
anc = [0]*n  # bitset of entries in history incl self
for i in range(n):
    a = 1 << i
    for p in par[i]: a |= anc[p]
    anc[i] = a
def weight(bits):
    s = 0
    while bits:
        low = bits & -bits; i = low.bit_length()-1; s += w[i]; bits ^= low
    return s
def cost(order):
    cur = 0; total = 0
    for i in order:
        target = 0
        for p in par[i]: target |= anc[p]
        total += weight(cur & ~target) + weight(target & ~cur)
        cur = anc[i]
    return total
print('entries', n, 'ops', sum(w))
print('LV order cost', cost(range(n)))
# DFS small-subtree-first
children = [[] for _ in range(n)]
for i in range(n):
    for p in par[i]: children[p].append(i)
sub = [0]*n
for i in reversed(range(n)):
    sub[i] = min(w[i] + sum(sub[c] for c in children[i]), 10**15)
indeg = [len(par[i]) for i in range(n)]
stack = [i for i in range(n) if indeg[i] == 0]
stack.sort(key=lambda i: -sub[i])
order = []
while stack:
    i = stack.pop(); order.append(i)
    ready = []
    for c in children[i]:
        indeg[c] -= 1
        if indeg[c] == 0: ready.append(c)
    ready.sort(key=lambda c: -sub[c])
    stack.extend(ready)
assert len(order) == n
print('DFS small-first cost', cost(order))
