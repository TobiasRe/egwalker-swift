import Foundation

/// The document text, stored as a gap buffer of Unicode scalars.
///
/// Why a gap buffer and not a rope? Real editing is local: people type and delete
/// near where they just typed. A gap buffer makes edits at the cursor O(1) and
/// only pays (one memmove) when the cursor jumps. For replaying editing traces
/// that is hard to beat, and it is ~150 lines with no allocation per edit.
/// (We measured a chunked rope as an alternative: it was slower. See LEARNING.md.)
///
/// Storage width adapts to the content, like Python's strings (PEP 393):
/// 1 byte per scalar while everything is Latin-1, 2 bytes once a BMP character
/// (e.g. a curly quote or "€") appears, 4 bytes only for astral characters such
/// as emoji. Most documents never need more than 2 bytes per character.
final class GapBuffer {
    /// Bytes per element: 1, 2 or 4.
    @exclusivity(unchecked) private(set) var width: Int = 1
    @exclusivity(unchecked) private var storage: UnsafeMutableRawPointer
    @exclusivity(unchecked) private var capacity: Int
    @exclusivity(unchecked) private var gapStart: Int = 0
    @exclusivity(unchecked) private var gapEnd: Int

    init(capacity: Int = 64) {
        self.capacity = Swift.max(capacity, 16)
        self.gapEnd = self.capacity
        storage = malloc(self.capacity)!
        rebind()
    }

    /// Tells Swift which element type the raw memory currently holds (strict
    /// aliasing rules: typed access must match the bound type).
    @inline(__always) private func rebind() {
        switch width {
        case 1: storage.bindMemory(to: UInt8.self, capacity: capacity)
        case 2: storage.bindMemory(to: UInt16.self, capacity: capacity)
        default: storage.bindMemory(to: UInt32.self, capacity: capacity)
        }
    }

    deinit { free(storage) }

    var count: Int { capacity - (gapEnd - gapStart) }
    var allocatedBytes: Int { capacity * width }

    @inline(__always) private static func width(for v: UInt32) -> Int {
        v <= 0xFF ? 1 : (v <= 0xFFFF ? 2 : 4)
    }

    @inline(__always) private func load(_ i: Int) -> UInt32 {
        switch width {
        case 1: return UInt32(storage.load(fromByteOffset: i, as: UInt8.self))
        case 2: return UInt32(storage.load(fromByteOffset: i &* 2, as: UInt16.self))
        default: return storage.load(fromByteOffset: i &* 4, as: UInt32.self)
        }
    }

    /// Moves `n` elements from index `src` to index `dst` (overlap allowed).
    @inline(__always) private func move(_ dst: Int, _ src: Int, _ n: Int) {
        if n <= 0 { return }
        (storage + dst * width).copyMemory(from: storage + src * width, byteCount: n * width)
    }

    private func moveGap(to pos: Int) {
        if pos == gapStart { return }
        let gapLen = gapEnd - gapStart
        if pos < gapStart { move(pos + gapLen, pos, gapStart - pos) }
        else { move(gapStart, gapEnd, pos - gapStart) }
        gapStart = pos
        gapEnd = pos + gapLen
    }

    /// Grows by 1.5x with `realloc`, which can extend the block in place (or, for
    /// large blocks, remap pages) instead of holding old and new copies at once.
    /// That keeps the *peak* heap close to the final size.
    private func grow(minExtra: Int) {
        let newCap = Swift.max(capacity + capacity / 2, count + minExtra + 16)
        let tail = capacity - gapEnd
        let newGapEnd = newCap - tail
        storage = realloc(storage, newCap * width)!
        move(newGapEnd, gapEnd, tail)
        capacity = newCap
        rebind()
        gapEnd = newGapEnd
    }

    /// Re-encodes the buffer with a wider element type, in place. We walk from the
    /// back so no element is overwritten before it has been read.
    private func widen(to newWidth: Int) {
        guard newWidth > width else { return }
        let old = width
        storage = realloc(storage, capacity * newWidth)!
        var i = capacity - 1
        while i >= 0 {
            if i < gapStart || i >= gapEnd {
                let v: UInt32 = old == 1
                    ? UInt32(storage.load(fromByteOffset: i, as: UInt8.self))
                    : UInt32(storage.load(fromByteOffset: i * 2, as: UInt16.self))
                if newWidth == 2 { storage.storeBytes(of: UInt16(v), toByteOffset: i * 2, as: UInt16.self) }
                else { storage.storeBytes(of: v, toByteOffset: i * 4, as: UInt32.self) }
            }
            i -= 1
        }
        width = newWidth
        rebind()
    }

    func insert(_ scalars: UnsafeBufferPointer<Unicode.Scalar>, at pos: Int) {
        precondition(pos >= 0 && pos <= count, "insert position \(pos) out of bounds (\(count))")
        let n = scalars.count
        if n == 0 { return }
        if width < 4 {
            var need = width
            for s in scalars {
                let w = Self.width(for: s.value)
                if w > need { need = w; if need == 4 { break } }
            }
            if need > width { widen(to: need) }
        }
        if gapEnd - gapStart < n { grow(minExtra: n) }
        moveGap(to: pos)
        switch width {
        case 1:
            let p = (storage + gapStart).assumingMemoryBound(to: UInt8.self)
            for i in 0..<n { p[i] = UInt8(truncatingIfNeeded: scalars[i].value) }
        case 2:
            let p = (storage + gapStart * 2).assumingMemoryBound(to: UInt16.self)
            for i in 0..<n { p[i] = UInt16(truncatingIfNeeded: scalars[i].value) }
        default:
            let p = (storage + gapStart * 4).assumingMemoryBound(to: UInt32.self)
            for i in 0..<n { p[i] = scalars[i].value }
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
        for i in 0..<gapStart { out.append(Unicode.Scalar(load(i))!) }
        for i in gapEnd..<capacity { out.append(Unicode.Scalar(load(i))!) }
        return out
    }
}
