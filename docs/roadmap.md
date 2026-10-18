# Limitations & roadmap

## Current limitations

- **No storage format.** `OpLog` lives in memory only. There is no binary encoding yet, and
  no reader or writer for diamond-types' `.dt` format.
- **No sync protocol.** `merge(from:)` copies whole oplogs, and event-by-event sync is left to
  the app. There is no version-summary exchange to compute what a peer is missing.
- **Untrusted input traps.** Remote events are not validated; a malformed event crashes rather
  than being rejected ([D10](decisions.md#d10-preconditions-instead-of-thrown-errors)).
- **No cursor transformation.** Merging doesn't yet report how local selections should move.
- **Incremental merge always tracks.** `TextDocument.merge` builds CRDT state even when the
  new events have no concurrency and could be fast-forwarded.
- **Plain text only.** No rich text (Peritext), no lists or maps.
- **Positions are Unicode scalars.** Apple text APIs use UTF-16, so conversion is the app's job
  ([API guide](api-guide.md#positions-are-unicode-scalars)).
- **Measured on x86 Linux only.** Apple Silicon numbers are pending.

## Performance next steps

Ordered by expected impact on the traces where diamond-types is still ahead (A1/A2):

1. **Compact spans.** `Span` is 40 bytes. With `Int32` LVs and a placeholder encoding it would
   be 20 bytes, so twice as many per cache line in the hottest structure.
2. **Store parent slots** in the B-tree instead of searching the 16-entry child array on every
   aggregate propagation.
3. **A cost model for traversal order** instead of the 64-entry threshold, ideally explaining
   why depth-first order is slower on the C traces.
4. **Run-length encoded `leafOf` / `delTarget`** to bring A2's peak memory below
   diamond-types' 5.8 MB.
5. **Fast-forward in incremental merge** for the common case of non-concurrent remote events.

## Feature next steps

- Binary oplog encoding (ideally `.dt`-compatible), plus loading only the tail of history.
- Version summaries and a minimal sync protocol.
- A validating, throwing ingestion API for remote events.
- Cursor and selection transformation across merges.
- A SwiftUI / TCA integration example with UTF-16 bridging.
- Mutation testing with schemata (compile once, switch mutants at runtime) for faster
  campaigns.
