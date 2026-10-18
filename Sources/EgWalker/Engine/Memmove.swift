/// memmove for trivial (POD) element types. Overlapping ranges are fine.
@inline(__always)
func memmoveElements<T>(_ dst: UnsafeMutablePointer<T>, _ src: UnsafeMutablePointer<T>, _ count: Int) {
    if count <= 0 { return }
    assert(_isPOD(T.self), "memmoveElements requires a trivial type")
    UnsafeMutableRawPointer(dst).copyMemory(from: UnsafeRawPointer(src), byteCount: count * MemoryLayout<T>.stride)
}
