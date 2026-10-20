import AppKit
import SwiftUI

/// R122: how far apart the rows of a task list stand, chosen in Settings.
enum RowSpacing {
    static let choices: [(String, String)] = [("Compact", "compact"), ("Normal", "normal"), ("Relaxed", "relaxed")]
    static let key = "rowSpacing"

    /// The choice a saved value stands for; anything else is the default.
    static func from(_ saved: String?) -> String {
        saved.flatMap { value in choices.first { $0.1 == value }?.1 } ?? "normal"
    }

    /// The space above and below the content of a row, in points.
    static func padding(_ choice: String) -> CGFloat {
        switch choice {
        case "compact": return 1
        case "relaxed": return 8
        default: return 3
        }
    }
}

/// Fonts of the app, scaled and styled by the user's choice in Settings.
///
/// macOS has no system-wide text size for apps to follow, so the app keeps its
/// own: every text style is the system size for that style times a factor.
enum AppFont {
    static let scales: [(String, Double)] = [("Small", 0.9), ("Regular", 1.0), ("Large", 1.15), ("Larger", 1.3), ("Largest", 1.5)]
    /// The size of a Mac on which none was chosen: the system one reads small in the window of Lists (R35, #397).
    static let defaultScale = 1.15
    static let designs: [(String, String)] = [("System", "default"), ("Rounded", "rounded"), ("Serif", "serif"), ("Monospaced", "monospaced")]

    static let scaleKey = "textScale"
    static let designKey = "fontDesign"

    private static func design(_ name: String) -> Font.Design {
        switch name {
        case "rounded": return .rounded
        case "serif": return .serif
        case "monospaced": return .monospaced
        default: return .default
        }
    }

    private static func base(_ style: Font.TextStyle) -> NSFont.TextStyle {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }

    /// Reads the model, so a view that uses it is redrawn when the setting changes.
    @MainActor
    static func style(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        let model = AppModel.shared
        let size = NSFont.preferredFont(forTextStyle: base(style)).pointSize * model.textScale
        let headline = style == .headline ? Font.Weight.semibold : nil
        return .system(size: size, weight: weight ?? headline ?? .regular, design: design(model.fontDesign))
    }

    /// The same font for AppKit views; `scale` stands in for the chosen size, as the sidebar's does (R161).
    @MainActor
    static func native(_ style: Font.TextStyle, scale: Double? = nil) -> NSFont {
        let model = AppModel.shared
        let size = NSFont.preferredFont(forTextStyle: base(style)).pointSize * (scale ?? model.textScale)
        let system = NSFont.systemFont(ofSize: size)
        let design: NSFontDescriptor.SystemDesign
        switch model.fontDesign {
        case "rounded": design = .rounded
        case "serif": design = .serif
        case "monospaced": design = .monospaced
        default: return system
        }
        return system.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? system
    }

    /// R161: a font of the sidebar, which grows half as fast as the text of the tasks.
    @MainActor
    static func sidebar(_ style: Font.TextStyle) -> NSFont {
        native(style, scale: SidebarText.scale(AppModel.shared.textScale))
    }
}
