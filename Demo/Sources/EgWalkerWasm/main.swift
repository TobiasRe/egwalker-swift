// A tiny C ABI around EgWalker for the browser demo.
//
// JavaScript owns the UI; Swift owns the replicas. Every replica is a real
// `OpLog`, and syncing is a real `merge(from:)`. Strings cross the boundary as
// UTF-8 bytes in Wasm memory; positions are Unicode scalar offsets, which is
// what EgWalker uses (JavaScript's `Array.from(string)` gives the same units).
//
// Built as a WASI "reactor": JavaScript calls `_initialize` once, then the
// exported functions below.
import EgWalker

#if canImport(WASILibc)
import WASILibc
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

nonisolated(unsafe) var replicas: [OpLog] = []
nonisolated(unsafe) var agents: [String] = []
nonisolated(unsafe) var resultBytes: [UInt8] = []
nonisolated(unsafe) var resultBuffer: UnsafeMutablePointer<UInt8>? = nil

/// Copies `bytes` into a buffer JavaScript can read; length via `eg_result_len`.
func publish(_ bytes: [UInt8]) -> UnsafeMutablePointer<UInt8>? {
    resultBuffer?.deallocate()
    let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(bytes.count, 1))
    bytes.withUnsafeBufferPointer { p.initialize(from: $0.baseAddress!, count: bytes.count) }
    resultBuffer = p
    resultBytes = bytes
    return p
}

func string(_ ptr: UnsafePointer<UInt8>?, _ len: Int32) -> String {
    guard let ptr, len > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: ptr, count: Int(len)), as: UTF8.self)
}

@_expose(wasm, "eg_alloc")
@_cdecl("eg_alloc")
func eg_alloc(_ size: Int32) -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer.allocate(byteCount: Int(max(size, 1)), alignment: 8)
}

@_expose(wasm, "eg_free")
@_cdecl("eg_free")
func eg_free(_ ptr: UnsafeMutableRawPointer?) { ptr?.deallocate() }

@_expose(wasm, "eg_result_len")
@_cdecl("eg_result_len")
func eg_result_len() -> Int32 { Int32(resultBytes.count) }

/// Creates `count` empty replicas with the given comma-separated agent names.
@_expose(wasm, "eg_reset")
@_cdecl("eg_reset")
func eg_reset(_ namesPtr: UnsafePointer<UInt8>?, _ namesLen: Int32) {
    agents = string(namesPtr, namesLen).split(separator: ",").map(String.init)
    replicas = agents.map { _ in OpLog() }
}

@_expose(wasm, "eg_insert")
@_cdecl("eg_insert")
func eg_insert(_ r: Int32, _ pos: Int32, _ textPtr: UnsafePointer<UInt8>?, _ textLen: Int32) {
    let text = string(textPtr, textLen)
    guard !text.isEmpty else { return }
    _ = replicas[Int(r)].insert(agent: agents[Int(r)], at: Int(pos), text)
}

@_expose(wasm, "eg_delete")
@_cdecl("eg_delete")
func eg_delete(_ r: Int32, _ pos: Int32, _ len: Int32) {
    guard len > 0 else { return }
    _ = replicas[Int(r)].delete(agent: agents[Int(r)], at: Int(pos), len: Int(len))
}

/// `dst` learns everything `src` knows. Returns how many events were new to `dst`.
@_expose(wasm, "eg_merge")
@_cdecl("eg_merge")
func eg_merge(_ dst: Int32, _ src: Int32) -> Int32 {
    let before = replicas[Int(dst)].count
    replicas[Int(dst)].merge(from: replicas[Int(src)])
    return Int32(replicas[Int(dst)].count - before)
}

/// Replays replica `r` and returns its text as UTF-8.
@_expose(wasm, "eg_text")
@_cdecl("eg_text")
func eg_text(_ r: Int32) -> UnsafeMutablePointer<UInt8>? {
    publish(Array(replicas[Int(r)].checkout().text.utf8))
}

@_expose(wasm, "eg_event_count")
@_cdecl("eg_event_count")
func eg_event_count(_ r: Int32) -> Int32 { Int32(replicas[Int(r)].count) }

/// Replays replica `r` and returns JSON: text, walker statistics and the event
/// graph grouped into runs (the same run-length encoding the library uses).
@_expose(wasm, "eg_state")
@_cdecl("eg_state")
func eg_state(_ r: Int32, _ maxRuns: Int32) -> UnsafeMutablePointer<UInt8>? {
    let oplog = replicas[Int(r)]
    let (scalars, stats) = oplog.checkoutWithStats()
    var text = String.UnicodeScalarView()
    text.append(contentsOf: scalars)

    var json = JSON()
    json.open("{")
    json.key("text"); json.string(String(text)); json.comma()
    json.key("events"); json.int(oplog.count); json.comma()
    json.key("graphEntries"); json.int(oplog.cg.entryCount); json.comma()
    json.key("opRuns"); json.int(oplog.runCount); json.comma()
    json.key("heads"); json.open("[")
    for (i, h) in oplog.cg.heads.enumerated() {
        if i > 0 { json.comma() }
        json.version(oplog.cg.lvToRaw(h))
    }
    json.close("]"); json.comma()
    json.key("stats"); json.open("{")
    json.key("fastForwarded"); json.int(stats.fastForwarded); json.comma()
    json.key("tracked"); json.int(stats.tracked); json.comma()
    json.key("sessions"); json.int(stats.trackingSessions); json.comma()
    json.key("retreated"); json.int(stats.retreated); json.comma()
    json.key("advanced"); json.int(stats.advanced)
    json.close("}"); json.comma()
    json.key("runs"); json.open("[")
    // Only the most recent events are grouped; the panel shows the tail anyway.
    let runs = eventRuns(oplog, from: max(0, oplog.count - 5_000))
    let shown = runs.suffix(Int(maxRuns))
    for (i, run) in shown.enumerated() {
        if i > 0 { json.comma() }
        json.open("{")
        json.key("lv"); json.int(run.start); json.comma()
        json.key("len"); json.int(run.end - run.start); json.comma()
        json.key("agent"); json.string(run.agent); json.comma()
        json.key("seq"); json.int(run.seq); json.comma()
        json.key("kind"); json.string(run.kind == .insert ? "ins" : "del"); json.comma()
        json.key("pos"); json.int(run.pos); json.comma()
        json.key("content"); json.string(run.content); json.comma()
        json.key("parents"); json.open("[")
        for (j, p) in run.parents.enumerated() {
            if j > 0 { json.comma() }
            json.version(oplog.cg.lvToRaw(p))
        }
        json.close("]")
        json.close("}")
    }
    json.close("]"); json.comma()
    json.key("shownFrom"); json.int(shown.first?.start ?? 0)
    json.close("}")
    return publish(json.bytes)
}

// MARK: - Event runs for display

struct EventRun {
    var start: LV, end: LV
    var agent: String, seq: Int
    var kind: OpKind, pos: Int
    var content: String
    var parents: [LV]
}

/// Groups events into runs: same agent, consecutive sequence numbers, each event's
/// only parent is the previous one, and the same kind of operation.
func eventRuns(_ oplog: OpLog, from first: LV) -> [EventRun] {
    var runs: [EventRun] = []
    var lv = first
    while lv < oplog.count {
        let raw = oplog.cg.lvToRaw(lv)
        let op = oplog.op(at: lv)
        var run = EventRun(start: lv, end: lv + 1, agent: raw.agent, seq: raw.seq, kind: op.kind,
                           pos: op.pos, content: op.content.map { String($0) } ?? "",
                           parents: oplog.cg.parents(of: lv))
        var next = lv + 1
        while next < oplog.count {
            let r2 = oplog.cg.lvToRaw(next)
            let op2 = oplog.op(at: next)
            guard r2.agent == raw.agent, r2.seq == raw.seq + (next - lv),
                  op2.kind == op.kind, oplog.cg.parents(of: next) == [next - 1] else { break }
            if let c = op2.content { run.content.unicodeScalars.append(c) }
            next += 1
        }
        run.end = next
        runs.append(run)
        lv = next
    }
    return runs
}

// MARK: - Minimal JSON writer (no Foundation needed)

struct JSON {
    var bytes: [UInt8] = []
    mutating func raw(_ s: String) { bytes.append(contentsOf: s.utf8) }
    mutating func open(_ c: String) { raw(c) }
    mutating func close(_ c: String) { raw(c) }
    mutating func comma() { raw(",") }
    mutating func key(_ k: String) { string(k); raw(":") }
    mutating func int(_ v: Int) { raw(String(v)) }
    mutating func version(_ v: RawVersion) { raw("["); string(v.agent); raw(","); int(v.seq); raw("]") }
    mutating func string(_ s: String) {
        raw("\"")
        for u in s.unicodeScalars {
            switch u {
            case "\"": raw("\\\"")
            case "\\": raw("\\\\")
            case "\n": raw("\\n")
            case "\r": raw("\\r")
            case "\t": raw("\\t")
            default:
                if u.value < 0x20 {
                    let hex = String(u.value, radix: 16)
                    raw("\\u" + String(repeating: "0", count: 4 - hex.count) + hex)
                } else {
                    bytes.append(contentsOf: String(u).utf8)
                }
            }
        }
        raw("\"")
    }
}
