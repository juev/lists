import AppKit

/// The choice of a tag for a card: a field for a new one and the tags there are.
@MainActor
final class TagPopoverView: NSView, NSTextFieldDelegate {
    private let add: (String) -> Void
    /// Closes the popover the view is in.
    var dismiss: () -> Void = {}
    private let field = NSTextField()

    init(known: [String], add: @escaping (String) -> Void) {
        self.add = add
        super.init(frame: .zero)
        field.placeholderString = L("Tag")
        field.target = self
        field.action = #selector(submit)
        let stack = NSStackView(views: [field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for tag in known.prefix(8) {
            let link = NSButton(title: "#\(tag)", target: self, action: #selector(choose(_:)))
            link.isBordered = false
            link.contentTintColor = .linkColor
            link.identifier = NSUserInterfaceItemIdentifier(tag)
            stack.addArrangedSubview(link)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 180),
        ])
        frame.size = fittingSize
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func submit() {
        let tag = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !tag.isEmpty { add(tag) }
        dismiss()
    }

    @objc private func choose(_ sender: NSButton) {
        if let tag = sender.identifier?.rawValue { add(tag) }
        dismiss()
    }
}
