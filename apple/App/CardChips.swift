import AppKit
import SwiftUI

/// The chips of a card that Tab stops at (R62), in an open task and in the card of a new one.
enum CardChip: Hashable {
    case start, due, `repeat`, remind, priority, tag(String), newTag, add, list, file
}

/// One choice of a chip's menu. The same choices make the menu a click opens
/// and the one the keyboard opens.
struct MenuChoice {
    let title: String
    /// The check mark of a choice that has one.
    var on: Bool?
    let action: () -> Void
}

/// The choices as the content of a SwiftUI menu.
struct ChoiceItems: View {
    let choices: [MenuChoice]

    var body: some View {
        ForEach(choices.indices, id: \.self) { index in
            let choice = choices[index]
            if let on = choice.on {
                Toggle(choice.title, isOn: Binding(get: { on }, set: { _ in choice.action() }))
            } else {
                Button(choice.title, action: choice.action)
            }
        }
    }
}

/// Where the menus of a card's chips are on screen: a SwiftUI menu cannot be
/// opened from code, so the keyboard opens an AppKit one under the same chip.
@MainActor
final class MenuAnchors {
    fileprivate final class Anchor { weak var view: NSView? }
    fileprivate var anchors: [CardChip: Anchor] = [:]
    private var actions: [() -> Void] = []

    fileprivate func anchor(_ chip: CardChip) -> Anchor {
        if let found = anchors[chip] { return found }
        let made = Anchor()
        anchors[chip] = made
        return made
    }

    /// Opens the choices as a menu under the chip and waits until it closes.
    func show(_ choices: [MenuChoice], under chip: CardChip) {
        guard let view = anchors[chip]?.view else { return }
        let menu = NSMenu()
        actions = choices.map(\.action)
        for (index, choice) in choices.enumerated() {
            let item = NSMenuItem(title: choice.title, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = choice.on == true ? .on : .off
            menu.addItem(item)
        }
        let below = NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4)
        menu.popUp(positioning: nil, at: below, in: view)
    }

    @objc private func pick(_ item: NSMenuItem) {
        guard actions.indices.contains(item.tag) else { return }
        actions[item.tag]()
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchors.Anchor

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

/// What the keys of a focused chip do besides opening it.
struct ChipKeys {
    /// Tab and ⇧Tab: one chip on or back from the given one.
    let step: (CardChip, Int) -> Void
    /// Esc: the card is done with.
    let cancel: () -> Void
}

private struct ChipStop: ViewModifier {
    let chip: CardChip
    var focus: FocusState<CardChip?>.Binding
    let keys: ChipKeys
    let open: () -> Void

    func body(content: Content) -> some View {
        content
            // Its own focus, not the key loop of the window: chips are tab stops there
            // only with "Keyboard navigation" on in System Settings.
            .focusable()
            .focusEffectDisabled()
            .focused(focus, equals: chip)
            .overlay {
                if focus.wrappedValue == chip {
                    Capsule().strokeBorder(Color.accentColor, lineWidth: 2).padding(-2).allowsHitTesting(false)
                }
            }
            .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}"), .space, .return, .escape], phases: .down) { press in
                switch press.key {
                case .tab: keys.step(chip, press.modifiers.contains(.shift) ? -1 : 1)
                // ⇧Tab comes as a character of its own.
                case KeyEquivalent("\u{19}"): keys.step(chip, -1)
                case .space, .return: open()
                case .escape: keys.cancel()
                default: return .ignored
                }
                return .handled
            }
    }
}

extension View {
    /// Makes a chip a stop for Tab; Space and Return on it call `open`.
    func chipStop(_ chip: CardChip, focus: FocusState<CardChip?>.Binding, keys: ChipKeys, open: @escaping () -> Void) -> some View {
        modifier(ChipStop(chip: chip, focus: focus, keys: keys, open: open))
    }

    /// Marks the place of a chip's menu for `MenuAnchors.show`.
    @MainActor
    func menuAnchor(_ anchors: MenuAnchors, _ chip: CardChip) -> some View {
        background(MenuAnchorView(anchor: anchors.anchor(chip)))
    }

    /// Tells the list around the card that a chip or the row of a file has the keyboard, so that
    /// Space and Return there are theirs. A debug build also shows the debug script which chip
    /// or file it is and which popover of the card is open.
    @MainActor
    func reportsCard(_ card: String, chip: CardChip?, file: String? = nil, popover: String?) -> some View {
        onChange(of: chip != nil || file != nil) { _, held in
            if held { Keyboard.cards.insert(card) } else { Keyboard.cards.remove(card) }
        }
        #if DEBUG
        .onChange(of: chip) { _, new in DebugScript.chip = new.map { "\($0)" } }
        .onChange(of: file) { _, new in DebugScript.file = new }
        #endif
        .onChange(of: popover) { _, new in
            #if DEBUG
            DebugScript.popover = new
            #endif
        }
        .onDisappear {
            Keyboard.cards.remove(card)
            #if DEBUG
            if file != nil { DebugScript.file = nil }
            #endif
        }
    }
}
