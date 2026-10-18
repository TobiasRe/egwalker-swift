# Concepts

This page explains the ideas the code is built on. It assumes no prior knowledge of CRDTs or
operational transformation.

## The problem

Several people edit the same text, sometimes offline. Eventually every replica must show the
same text (*convergence*), and the result should be what a human expects: if two people type
words at the same place at the same time, the words must not be interleaved letter by letter.

Until recently there were two families of solutions:

| | Operational Transformation (OT) | CRDTs (Yjs, Automerge, …) |
|---|---|---|
| An operation says | "insert `x` at position 5" | "insert `x` after the character with ID `(alice, 17)`" |
| Strength | compact; loading a document is cheap | merging long-diverged branches is O(n log n) |
| Weakness | merging long-diverged branches is O(n²) or worse | every character carries permanent metadata; loading is expensive |

**Eg-walker** (Gentle & Kleppmann, *Collaborative Text Editing with Eg-walker: Better, Faster,
Smaller*, EuroSys 2025) combines the strengths of both. It *stores* history like OT (operations
with plain integer positions) and *merges* like a CRDT, but builds the CRDT state only
temporarily, only for the part of history that is actually concurrent, and throws it away
afterwards.

## Events and the event graph

Every single-character insert or delete is an **event**. Each event has:

- a globally unique **ID** `(agent, seq)`: the agent's name plus a per-agent counter;
- its **parents**: the events its author had seen when making it (the version it was made at);
- an **operation**: insert character `c` at position `p`, or delete the character at `p`.

Positions refer to the document *as it was at the event's parents*. That is the OT half of the
design: operations are just integers, and nothing in the stored history refers to other
characters by ID.

The events and their parent edges form a directed acyclic graph, the **event graph** (also
called the causal graph). This graph plus the operations is the *only* state that needs to be
stored or synced. The text is derived from it.

## Local versions

Comparing `(agent, seq)` pairs is slow, so each replica numbers events `0, 1, 2, …` in the
order it learned about them. This number is the **local version (LV)**. Because an event can
only be added after all of its parents, LV order is always a **topological order** of the
graph: parents have smaller LVs than children. A great deal of the code relies on this.

LVs differ between replicas. They are never sent over the network; IDs are.

## Versions and frontiers

A **version** is a set of events closed under "has parent". It is represented by its
**frontier**: the events in it that no other event in it depends on. A linear history has a
one-element frontier. Right after two people edit concurrently, the frontier has two elements.
`CausalGraph.heads` is the frontier of everything a replica knows.

Two useful operations on versions:

- **diff(a, b)**: which events are in the history of `a` but not `b`, and vice versa.
- **common ancestor**: the latest version contained in both.

## Replaying history: the walker

To produce text, Eg-walker *walks* the event graph in topological order and applies each
operation. The difficulty: an operation's position refers to the document at the event's
parents, but the walker's document already contains concurrent edits the event's author never
saw.

The walker solves this with a temporary CRDT. For each character it keeps an **item** with two
states:

- **current state**: is the item visible at the version the walker is *currently looking at*?
  (not yet inserted, inserted, or deleted)
- **end state**: is it visible once *everything* processed so far is applied? This determines
  where it sits in the output text.

To apply an event, the walker first moves its current state to the event's parent version:
it **retreats** (un-applies) events that aren't in the event's history and **advances**
(re-applies) events that are. Now the event's integer position is valid against the current
state. The walker finds the referenced item, then maps it to a position in the end state, and
edits the text there.

When two inserts land at the same place concurrently, their order is decided by the
**YjsMod/Fugue** rules: each item remembers its left neighbour at insert time (origin-left) and
a "right parent". Ties fall back to comparing agent names. This is what prevents interleaving.

## Critical versions: why it's fast

An event `x` is **critical** when nothing can ever be concurrent with it:

1. every event before it (in LV order) is in its history, and
2. every event after it has it in its history.

At a critical event, the document the walker has built is exactly the document at `x`'s
parents. So `x`'s position is already correct, and it can be applied directly to the text,
with no CRDT at all. This is called **fast-forwarding**.

Between critical events, the walker builds CRDT state. At the next critical event, it throws
that state away. Characters that existed before a CRDT session started are represented by
**placeholders**, one compact run standing in for the whole existing document.

Consequences:

- One person typing never builds CRDT state. Replaying a long solo history is about as fast as
  replaying the keystrokes into a text buffer.
- Memory for CRDT state is proportional to how much concurrency there is, not to document size
  or history length.

## Run-length encoding

People type and delete in runs. Typing "hello" produces five events, but they share an agent,
have consecutive sequence numbers, and each has the previous one as its only parent. All
storage in this library is run-length encoded along those lines: causal-graph entries,
operation runs, and CRDT items. A paste of 10 000 characters is one entry, one op run and one
item span.

## Glossary

| Term | Meaning |
|---|---|
| Agent | A writer identity. Must be unique per replica that writes. |
| Event | One single-character insert or delete. |
| LV | Local version: an event's index in this replica's oplog. |
| Frontier | The minimal set of events that identifies a version. |
| Oplog | Event graph plus operations: the persistent state. |
| Checkout | Replaying an oplog into text. |
| Retreat / advance | Moving the CRDT's current state backwards / forwards over events. |
| NYI | "Not yet inserted": an item that doesn't exist at the walker's current version. |
| Critical event | An event no other event can be concurrent with. |
| Placeholder | A stand-in item for text that existed before a CRDT session began. |
| Span | A run of CRDT items typed left to right, stored as one record. |
