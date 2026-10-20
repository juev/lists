import Foundation

/// R161: a section of the sidebar that collapses with a click on its heading.
enum SidebarSection: String, CaseIterable {
    case lists, tags, projects, filters
}

/// R161: which sections of the sidebar are collapsed; kept on this Mac and not synced.
enum SidebarFolding {
    static let key = "sidebarFolded"

    /// The collapsed sections as the settings keep them; a name of no section is left out.
    static func folded(_ stored: [String]?) -> Set<SidebarSection> {
        Set((stored ?? []).compactMap(SidebarSection.init(rawValue:)))
    }

    /// The collapsed sections as they are kept, in a stable order.
    static func stored(_ folded: Set<SidebarSection>) -> [String] {
        SidebarSection.allCases.filter(folded.contains).map(\.rawValue)
    }

    /// The rows a section shows: all of them, or, collapsed, only the row of the open view.
    static func shown<T>(_ rows: [T], folded: Bool, isOpen: (T) -> Bool) -> [T] {
        folded ? rows.filter(isOpen) : rows
    }
}

/// R161: the text of the sidebar grows half as fast as the text of the tasks, so that its narrow column
/// does not look larger than the list.
enum SidebarText {
    /// The factor of the sidebar at the size step `textScale` (R35).
    static func scale(_ textScale: Double) -> Double { 1 + (textScale - 1) / 2 }
}
