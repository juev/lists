import Foundation

/// R35: the steps of the text size on macOS, as factors of the system size.
enum TextSize {
    /// "Regular" is larger than the system size, which reads small in the window of Lists (#397).
    static let steps: [(String, Double)] = [("Small", 1.0), ("Regular", 1.15), ("Large", 1.3), ("Larger", 1.5), ("Largest", 1.7)]
    static let regular = 1.15

    /// The step a saved factor stands for: nothing saved is "Regular", a factor of an earlier version is the nearest step.
    static func step(_ saved: Double?) -> Double {
        guard let saved else { return regular }
        return steps.map(\.1).min { abs($0 - saved) < abs($1 - saved) } ?? regular
    }
}
