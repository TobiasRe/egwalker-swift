/// A minimal binary max-heap.
///
/// The causal-graph algorithms (diff, dominators, conflict search) all walk the
/// graph *backwards in time*: they repeatedly pull the highest local version out
/// of a queue and replace it by its parents. A max-heap is exactly that queue.
///
/// We keep this tiny and dependency-free instead of pulling in swift-collections
/// so the library has zero dependencies.

struct MaxHeap<Element> {
    var storage: ContiguousArray<Element> = []
    let isLess: (Element, Element) -> Bool

    init(isLess: @escaping (Element, Element) -> Bool) {
        self.isLess = isLess
    }

    var isEmpty: Bool { storage.isEmpty }
    var count: Int { storage.count }
    var peek: Element? { storage.first }

    mutating func push(_ e: Element) {
        storage.append(e)
        var child = storage.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            if !isLess(storage[parent], storage[child]) { break }
            storage.swapAt(parent, child)
            child = parent
        }
    }

    @discardableResult mutating func pop() -> Element? {
        guard !storage.isEmpty else { return nil }
        if storage.count == 1 { return storage.removeLast() }
        let top = storage[0]
        storage[0] = storage.removeLast()
        var parent = 0
        let n = storage.count
        while true {
            let l = 2 * parent + 1
            if l >= n { break }
            let r = l + 1
            var largest = l
            if r < n && isLess(storage[l], storage[r]) { largest = r }
            if !isLess(storage[parent], storage[largest]) { break }
            storage.swapAt(parent, largest)
            parent = largest
        }
        return top
    }
}

extension MaxHeap where Element: Comparable {
    init() { self.init(isLess: <) }
}
