import AppKit
import RemoraCore

/// One saved connection: icon, name, a secondary subtitle, and trailing detail text that gives way
/// to an action button while the pointer is over the row. Without a session tab the detail is the
/// last-connected date and the action is Connect. With one, a status dot leads the subtitle, the
/// detail names the session state, and the action is Disconnect until the session ends.
@MainActor
final class ConnectionCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ConnectionCell")

    let actionButton = NSButton(title: "Connect", target: nil, action: nil)
    var isHovered = false {
        didSet { updateTrailingViews() }
    }

    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let statusView = NSImageView()
    private let addressField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        iconView.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        imageView = iconView

        nameField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        nameField.lineBreakMode = .byTruncatingTail
        textField = nameField

        addressField.font = .preferredFont(forTextStyle: .subheadline)
        addressField.textColor = .secondaryLabelColor
        addressField.lineBreakMode = .byTruncatingTail

        for field in [nameField, addressField] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        statusView.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        statusView.setContentHuggingPriority(.required, for: .horizontal)
        statusView.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusView.isHidden = true

        detailField.font = .preferredFont(forTextStyle: .subheadline)
        detailField.textColor = .secondaryLabelColor
        detailField.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailField.setContentHuggingPriority(.required, for: .horizontal)

        actionButton.controlSize = .small
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.isHidden = true

        let subtitle = NSStackView(views: [statusView, addressField])
        subtitle.orientation = .horizontal
        subtitle.alignment = .centerY
        subtitle.spacing = 4
        subtitle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let labels = NSStackView(views: [nameField, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [iconView, labels, detailField, actionButton])
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

    /// - Parameter session: The state of the connection's session tab, or nil without one.
    func configure(with connection: Connection, session: SessionState?, hovered: Bool) {
        let subtitle = Self.subtitle(for: connection)
        nameField.stringValue = connection.name
        addressField.stringValue = subtitle
        if let session {
            // A palette color keeps the dot green or orange on a selected row too.
            statusView.symbolConfiguration = Self.statusSymbolConfiguration
                .applying(NSImage.SymbolConfiguration(paletteColors: [session.statusColor]))
            statusView.isHidden = false
            detailField.stringValue = session.statusTitle
            actionButton.title = session.isLive ? "Disconnect" : "Connect"
            setAccessibilityLabel([connection.name, session.statusTitle.lowercased(), subtitle].joined(separator: ", "))
        } else {
            statusView.isHidden = true
            detailField.stringValue = connection.lastConnected.map {
                $0.formatted(Date.RelativeFormatStyle(
                    allowedFields: [.year, .month, .week, .day],
                    presentation: .named,
                    unitsStyle: .wide,
                    capitalizationContext: .beginningOfSentence
                ))
            } ?? ""
            actionButton.title = "Connect"
            var label = [connection.name, subtitle]
            if !detailField.stringValue.isEmpty {
                label.append("last connected \(detailField.stringValue.lowercased())")
            }
            setAccessibilityLabel(label.joined(separator: ", "))
        }
        // AppKit's row and cell elements drop identifiers, so the name carries the connection's ID.
        // It also offers the hover button's action, so agents and VoiceOver reach it without a pointer.
        nameField.cell?.setAccessibilityIdentifier("connection-\(connection.id.uuidString)")
        nameField.cell?.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: actionButton.title) { [weak self] in
            guard let self, let action = actionButton.action else { return false }
            return actionButton.sendAction(action, to: actionButton.target)
        }])
        isHovered = hovered
    }

    /// The cell's label carries the account and detail text, so only the name and the hover button,
    /// while it shows, are elements. The icon and status dot are decorative.
    override func accessibilityChildren() -> [Any]? {
        [nameField.cell, actionButton.isHidden ? nil : actionButton].compactMap { $0 }
    }

    private static let statusSymbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)

    /// The account and address, leaving out the address when the name already shows it.
    static func subtitle(for connection: Connection) -> String {
        let name = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let showsAddress = name.caseInsensitiveCompare(connection.host) != .orderedSame
            && name.caseInsensitiveCompare(connection.displayAddress) != .orderedSame
        let address = showsAddress ? connection.displayAddress : (connection.port == Connection.defaultPort ? "" : "Port \(connection.port)")
        switch (connection.username.isEmpty, address.isEmpty) {
        case (true, true): return "Remote Desktop"
        case (true, false): return address
        case (false, true): return connection.username
        case (false, false): return showsAddress ? "\(connection.username)@\(address)" : "\(connection.username) · \(address)"
        }
    }

    private func updateTrailingViews() {
        actionButton.isHidden = !isHovered
        detailField.isHidden = isHovered || detailField.stringValue.isEmpty
    }
}
