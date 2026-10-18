# EgWalker documentation

| Document | Read it when you want to… |
|---|---|
| [Concepts](concepts.md) | understand the problem Eg-walker solves and the vocabulary used everywhere else (events, local versions, frontiers, critical versions). Start here. |
| [API guide](api-guide.md) | use the library: editing, syncing replicas, keeping a document open, importing traces, and the preconditions you must respect. |
| [Architecture](architecture.md) | read or change the code: module map, data structures, and how a checkout and an incremental merge actually run. |
| [Testing](testing.md) | know what is verified and how: the oracle, fuzzing, invariants, sanitizers and mutation testing. |
| [Performance](performance.md) | see benchmark methodology and results, and the optimisation log (including what did *not* work). |
| [Design decisions](decisions.md) | understand why things are the way they are, in short decision records. |
| [Limitations & roadmap](roadmap.md) | know what the library does not do yet and where the next gains are. |

Conventions used throughout:

- **Positions** are counted in Unicode scalars (code points), not grapheme clusters and not
  UTF-16 code units. See [API guide → Positions](api-guide.md#positions-are-unicode-scalars).
- **LV** means *local version*: the index of an event in one replica's oplog.
- File references like `Engine/Walker.swift` are relative to `Sources/EgWalker/`.
