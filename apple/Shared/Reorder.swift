/// R123: moving tasks to another place of a list sorted by hand.
enum Reorder {
    /// The moves that put `moving` together before the place `destination` of `order`, keeping their order in `order`:
    /// each task goes after the one named, or first for none. Made one after the other, they give the new order.
    static func moves(_ order: [String], moving: [String], to destination: Int) -> [(id: String, after: String?)] {
        let moved = Set(moving)
        let kept = order.filter { !moved.contains($0) }
        let block = order.filter(moved.contains)
        let place = order.prefix(max(destination, 0)).filter { !moved.contains($0) }.count
        var result = kept
        result.insert(contentsOf: block, at: place)
        guard result != order else { return [] }
        return block.map { id in
            let index = result.firstIndex(of: id) ?? 0
            return (id, index > 0 ? result[index - 1] : nil)
        }
    }
}
