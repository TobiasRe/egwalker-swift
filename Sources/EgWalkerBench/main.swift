import EgWalker
import Foundation
let trace = try TraceImport.loadConcurrentTrace(URL(fileURLWithPath: CommandLine.arguments[1]))
let oplog = TraceImport.oplog(from: trace)
let (text, stats) = oplog.checkoutWithStats()
print(stats)
try Branch(scalars: text).text.write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
