// Benchmark harness: replays a trace with the optimized walker and reports
// timing and heap usage in the same JSON shape as the Rust harness.
//
//   egwalker-bench <trace.dt.json | trace.json> [iterations]
//
// Run under LD_PRELOAD=Benchmarks/memtrack/libmemtrack.so for heap numbers.
import EgWalker
import Foundation
#if canImport(Glibc)
import Glibc
#endif

typealias MemFn = @convention(c) () -> Int
func sym(_ name: String) -> MemFn? {
    #if canImport(Glibc)
    guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: 0), name) else { return nil }
    return unsafeBitCast(p, to: MemFn.self)
    #else
    return nil
    #endif
}
let memCurrent = sym("memtrack_current")
let memPeak = sym("memtrack_peak")
let memReset = sym("memtrack_reset_peak")

let args = CommandLine.arguments
let path = args[1]
let iters = args.count > 2 ? Int(args[2])! : 20
let url = URL(fileURLWithPath: path)
let name = url.lastPathComponent.components(separatedBy: ".").first!

let oplog: OpLog
let expected: String
if path.hasSuffix(".dt.json") {
    let data = try TraceImport.loadDTExport(url)
    oplog = TraceImport.oplog(from: data)
    expected = data.endContent
} else {
    let trace = try TraceImport.loadConcurrentTrace(url)
    oplog = TraceImport.oplog(from: trace)
    expected = trace.endContent
}

// Correctness first: a benchmark of a wrong answer is worthless.
let first = oplog.checkoutDocument()
let correct = first.text == expected
let stats = oplog.checkoutWithStats().stats

// Memory: heap growth during one checkout, relative to the loaded oplog.
memReset?()
let base = memCurrent?() ?? 0
var doc: TextDocument? = oplog.checkoutDocument()
let peak = (memPeak?() ?? 0) - base
let retained = (memCurrent?() ?? 0) - base
let docLen = doc!.count
doc = nil

var times: [Double] = []
for _ in 0..<iters {
    let t0 = DispatchTime.now().uptimeNanoseconds
    let d = oplog.checkoutDocument()
    let t1 = DispatchTime.now().uptimeNanoseconds
    times.append(Double(t1 - t0) / 1e6)
    withExtendedLifetime(d) {}
}
times.sort()
let median = times[times.count / 2]
let fmt = { (x: Double) in String(format: "%.3f", x) }
print("{\"impl\":\"egwalker-swift\",\"trace\":\"\(name)\",\"ops\":\(oplog.count),\"docLen\":\(docLen),\"medianMs\":\(fmt(median)),\"minMs\":\(fmt(times[0])),\"peakHeapBytes\":\(peak),\"retainedBytes\":\(retained),\"correct\":\(correct),\"fastForwarded\":\(stats.fastForwarded),\"tracked\":\(stats.tracked),\"sessions\":\(stats.trackingSessions)}")
