import Foundation

/// The chips of a card that Tab stops at (R62), in an open task and in the card of a new one.
enum CardChip: Hashable {
    case start, due, `repeat`, remind, priority, tag(String), newTag, subtask, list, file
}

/// One choice of a chip's menu. The same choices make the menu a click opens
/// and the one the keyboard opens.
struct MenuChoice {
    let title: String
    /// The check mark of a choice that has one.
    var on: Bool?
    let action: () -> Void
    /// The title of a group of the choices that follow it.
    var isHeader = false

    static func header(_ title: String) -> MenuChoice { MenuChoice(title: title, action: {}, isHeader: true) }
}
