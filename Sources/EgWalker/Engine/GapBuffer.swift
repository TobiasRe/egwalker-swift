/// The document text, stored as a gap buffer of Unicode scalars.
///
/// Why a gap buffer and not a rope? Real editing is local: people type and delete
/// near where they just typed. A gap buffer makes edits at the cursor O(1) and
/// only pays (one memmove) when the cursor jumps. For replaying editing traces
/// that is hard to beat, and it is ~60 lines with no allocation per edit.
///
/// Storage starts as one byte per scalar (Latin-1). The first scalar above U+00FF
/// widens the buffer to 4 bytes per scalar. Most documents never widen, which
/// keeps the memory footprint at ~1 byte per character.
final class GapBuffer {
    private var narrow: UnsafeMutablePointer<UInt8>?
    private var wide: UnsafeMutablePointer<UInt32>?
    private var capacity: Int
    private var gapStart: Int = 0
    private var gapEnd: Int

    init(capacity: Int = 64) {
        self.capacity = Swift.max(capacity, 16)
        self.gapEnd = self.capacity
        narrow = .allocate(capacity: self.capacity)
    }

    deinit {
        narrow?.deallocate()
        wide?.deallocate()
    }

    var count: Int { capacity - (gapEnd - gapStart) }
    var isWide: Bool { wide != nil }
    var allocatedBytes: Int { capacity * (wide != nil ? 4 : 1) }

    private func moveGap(to pos: Int) {
        if pos == gapStart { return }
        let gapLen = gapEnd - gapStart
        if let w = wide {
            if pos < gapStart { memmoveElements(w + pos + gapLen, w + pos, gapStart - pos) }
            else { memmoveElements(w + gapStart, w + gapEnd, pos - gapStart) }
        } else if let n = narrow {
            if pos < gapStart { memmoveElements(n + pos + gapLen, n + pos, gapStart - pos) }
            else { memmoveElements(n + gapStart, n + gapEnd, pos - gapStart) }
        }
        gapStart = pos
        gapEnd = pos + gapLen
    }

    private func grow(minExtra: Int) {
        let newCap = Swift.max(capacity * 2, count + minExtra + 16)
        let tail = capacity - gapEnd
        let newGapEnd = newCap - tail
        if let w = wide {
            let nw = UnsafeMutablePointer<UInt32>.allocate(capacity: newCap)
            nw.update(from: w, count: gapStart)
            (nw + newGapEnd).update(from: w + gapEnd, count: tail)
            w.deallocate(); wide = nw
        } else if let n = narrow {
            let nn = UnsafeMutablePointer<UInt8>.allocate(capacity: newCap)
            nn.update(from: n, count: gapStart)
            (nn + newGapEnd).update(from: n + gapEnd, count: tail)
            n.deallocate(); narrow = nn
        }
        capacity = newCap
        gapEnd = newGapEnd
    }

    private func widen() {
        guard let n = narrow else { return }
        let w = UnsafeMutablePointer<UInt32>.allocate(capacity: capacity)
        for i in 0..<gapStart { w[i] = UInt32(n[i]) }
        for i in gapEnd..<capacity { w[i] = UInt32(n[i]) }
        n.deallocate()
        narrow = nil
        wide = w
    }

    func insert(_ scalars: UnsafeBufferPointer<Unicode.Scalar>, at pos: Int) {
        precondition(pos >= 0 && pos <= count, "insert position \(pos) out of bounds (\(count))")
        let n = scalars.count
        if n == 0 { return }
        if narrow != nil {
            for s in scalars where s.value > 0xFF { widen(); break }
        }
        if gapEnd - gapStart < n { grow(minExtra: n) }
        moveGap(to: pos)
        if let w = wide {
            for i in 0..<n { w[gapStart + i] = scalars[i].value }
        } else if let nn = narrow {
            for i in 0..<n { nn[gapStart + i] = UInt8(truncatingIfNeeded: scalars[i].value) }
        }
        gapStart += n
    }

    func delete(at pos: Int, count n: Int) {
        precondition(pos >= 0 && n >= 0 && pos + n <= count, "delete range out of bounds")
        if n == 0 { return }
        moveGap(to: pos)
        gapEnd += n
    }

    var scalars: [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(count)
        func push(_ v: UInt32) { out.append(Unicode.Scalar(v)!) }
        if let w = wide {
            for i in 0..<gapStart { push(w[i]) }
            for i in gapEnd..<capacity { push(w[i]) }
        } else if let n = narrow {
            for i in 0..<gapStart { out.append(Unicode.Scalar(n[i])) }
            for i in gapEnd..<capacity { out.append(Unicode.Scalar(n[i])) }
        }
        return out
    }
}
