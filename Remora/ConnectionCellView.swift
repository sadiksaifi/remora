import AppKit
import RemoraCore

/// One saved connection: icon, bold name, secondary address, and a trailing last-connected date
/// that gives way to a Connect button while the pointer is over the row.
@MainActor
final class ConnectionCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ConnectionCell")

    let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    var isHovered = false {
        didSet { updateTrailingViews() }
    }

    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let addressField = NSTextField(labelWithString: "")
    private let dateField = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        iconView.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        imageView = iconView

        nameField.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        nameField.lineBreakMode = .byTruncatingTail
        textField = nameField

        addressField.font = .preferredFont(forTextStyle: .subheadline)
        addressField.textColor = .secondaryLabelColor
        addressField.lineBreakMode = .byTruncatingTail

        for field in [nameField, addressField] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        dateField.font = .preferredFont(forTextStyle: .subheadline)
        dateField.textColor = .secondaryLabelColor
        dateField.setContentCompressionResistancePriority(.required, for: .horizontal)
        dateField.setContentHuggingPriority(.required, for: .horizontal)

        connectButton.controlSize = .small
        connectButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        connectButton.setContentHuggingPriority(.required, for: .horizontal)
        connectButton.isHidden = true

        let labels = NSStackView(views: [nameField, addressField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [iconView, labels, dateField, connectButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        row.setCustomSpacing(10, after: iconView)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 28),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("Use init()")
    }

    func configure(with connection: Connection, hovered: Bool) {
        nameField.stringValue = connection.name
        addressField.stringValue = connection.displayAddress
        dateField.stringValue = connection.lastConnected.map {
            $0.formatted(Date.RelativeFormatStyle(
                allowedFields: [.year, .month, .week, .day],
                presentation: .named,
                unitsStyle: .wide,
                capitalizationContext: .beginningOfSentence
            ))
        } ?? ""
        isHovered = hovered
        setAccessibilityLabel([connection.name, connection.displayAddress].joined(separator: ", "))
    }

    private func updateTrailingViews() {
        connectButton.isHidden = !isHovered
        dateField.isHidden = isHovered || dateField.stringValue.isEmpty
    }
}
