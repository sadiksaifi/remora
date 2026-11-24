import AppKit
import RemoraCore

/// One saved connection: icon, name, a secondary subtitle, a trailing status, and an action button
/// beside the status while the pointer is over the row. Without a session tab the status is the
/// last-connected date and the action is Connect. With one, the status is the session's one status,
/// as its tab shows it, and the action is Disconnect until the session ends.
@MainActor
final class ConnectionCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ConnectionCell")

    let actionButton = NSButton(title: "Connect", target: nil, action: nil)
    var showsAction = false {
        didSet { actionButton.isHidden = !showsAction }
    }

    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let addressField = NSTextField(labelWithString: "")
    private let statusView = NSImageView()
    private let spinner = NSProgressIndicator()
    private let statusField = NSTextField(labelWithString: "")
    private let status = NSStackView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        iconView.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        imageView = iconView

        nameField.font = .systemFont(ofSize: NSFont.systemFontSize)
        nameField.lineBreakMode = .byTruncatingTail
        textField = nameField

        addressField.font = .preferredFont(forTextStyle: .subheadline)
        addressField.textColor = .secondaryLabelColor
        addressField.lineBreakMode = .byTruncatingTail

        for field in [nameField, addressField] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        spinner.style = .spinning
        spinner.controlSize = .small
        statusField.font = .preferredFont(forTextStyle: .callout)
        statusField.textColor = .secondaryLabelColor
        status.setViews([statusView, spinner, statusField], in: .leading)
        status.orientation = .horizontal
        status.alignment = .centerY
        status.spacing = 6
        status.setHuggingPriority(.required, for: .horizontal)
        for view in [statusView, spinner, statusField] {
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            view.setContentHuggingPriority(.required, for: .horizontal)
        }

        actionButton.controlSize = .small
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.isHidden = true

        let labels = NSStackView(views: [nameField, addressField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [iconView, labels, status, actionButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 12
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

    /// - Parameters:
    ///   - tab: The connection's session tab, or nil without one.
    ///   - isRecording: Whether that session records, which the tab does not hold.
    func configure(with connection: Connection, tab: SessionTabs.Tab?, isRecording: Bool, showsAction: Bool) {
        let subtitle = Self.subtitle(for: connection)
        nameField.stringValue = connection.name
        addressField.stringValue = subtitle
        var label = [connection.name]
        if let tab {
            let status = Status(tab: tab, isRecording: isRecording)
            statusField.stringValue = status.title
            show(status.mark)
            actionButton.title = tab.state.isLive ? "Disconnect" : "Connect"
            label += [status.title.lowercased(), subtitle]
        } else {
            statusField.stringValue =
                connection.lastConnected.map {
                    $0.formatted(
                        Date.RelativeFormatStyle(
                            allowedFields: [.year, .month, .week, .day],
                            presentation: .named,
                            unitsStyle: .wide,
                            capitalizationContext: .beginningOfSentence
                        ))
                } ?? ""
            show(.none)
            actionButton.title = "Connect"
            label.append(subtitle)
            if !statusField.stringValue.isEmpty {
                label.append("last connected \(statusField.stringValue.lowercased())")
            }
        }
        status.isHidden = statusField.stringValue.isEmpty
        setAccessibilityLabel(label.joined(separator: ", "))
        // AppKit's row and cell elements drop identifiers, so the name carries the connection's ID.
        // It also offers the hover button's action, so agents and VoiceOver reach it without a pointer.
        nameField.cell?.setAccessibilityIdentifier("connection-\(connection.id.uuidString)")
        nameField.cell?.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: actionButton.title) { [weak self] in
                guard let self, let action = actionButton.action else { return false }
                return actionButton.sendAction(action, to: actionButton.target)
            }
        ])
        self.showsAction = showsAction
    }

    /// The cell's label carries the account and status text, so only the name and the hover button,
    /// while it shows, are elements. The icon and the status mark are decorative.
    override func accessibilityChildren() -> [Any]? {
        [nameField.cell, actionButton.isHidden ? nil : actionButton].compactMap { $0 }
    }

    /// A selected row turns its text white. An untinted symbol follows, and a tinted one would not.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { statusView.contentTintColor = backgroundStyle == .emphasized ? nil : .secondaryLabelColor }
    }

    /// A session's one status as the row words it, with the mark that leads the words.
    private struct Status {
        enum Mark {
            case none
            case spinner
            /// A 7 pt dot. Its palette color stays on a selected row.
            case dot(NSColor)
            /// A symbol in the text's color, or in a palette color that stays on a selected row.
            case symbol(String, NSColor?)
        }

        let title: String
        let mark: Mark

        init(tab: SessionTabs.Tab, isRecording: Bool) {
            let indicator = SessionIndicator(
                state: tab.state, hasWaitingRequest: tab.needsAttention, control: tab.control, isRecording: isRecording)
            title =
                switch indicator {
                case .needsAttention where tab.state == .connected: "Needs Attention"
                case .agentInControl, .agentPaused: tab.control.agentStatus(tab.agentName) ?? tab.state.statusTitle
                case .recording: "Recording"
                case .needsAttention, .connecting, .disconnected, .none: tab.state.statusTitle
                }
            mark =
                switch (indicator, indicator.symbolName) {
                case (.recording, _): .dot(.systemRed)
                case (.none, _): .dot(.systemGreen)
                case (.needsAttention, let name?): .symbol(name, .systemOrange)
                case (_, let name?): .symbol(name, nil)
                case (_, nil): .spinner
                }
        }
    }

    private func show(_ mark: Status.Mark) {
        let image: (name: String, size: CGFloat, color: NSColor?)? =
            switch mark {
            case .none, .spinner: nil
            case .dot(let color): ("circle.fill", 7, color)
            case .symbol(let name, let color): (name, 12, color)
            }
        if let image {
            let size = NSImage.SymbolConfiguration(pointSize: image.size, weight: .regular)
            statusView.image = NSImage(systemSymbolName: image.name, accessibilityDescription: nil)
            statusView.symbolConfiguration = image.color.map { size.applying(.init(paletteColors: [$0])) } ?? size
        }
        statusView.isHidden = image == nil
        if case .spinner = mark {
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.isHidden = true
            spinner.stopAnimation(nil)
        }
    }

    /// The account, the address unless the name already shows it, and the protocol.
    static func subtitle(for connection: Connection) -> String {
        let name = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let showsAddress =
            name.caseInsensitiveCompare(connection.host) != .orderedSame
            && name.caseInsensitiveCompare(connection.displayAddress) != .orderedSame
        let address = showsAddress ? connection.displayAddress : (connection.port == connection.defaultPort ? "" : "Port \(connection.port)")
        let account: String? =
            switch (connection.username.isEmpty, address.isEmpty) {
            case (true, true): nil
            case (true, false): address
            case (false, true): connection.username
            case (false, false): showsAddress ? "\(connection.username)@\(address)" : "\(connection.username) · \(address)"
            }
        return [account, connection.kind.title].compactMap { $0 }.joined(separator: " · ")
    }
}

extension Connection.Kind {
    /// The protocol's short name in the editor and the connections list.
    var title: String {
        switch self {
        case .rdp: "RDP"
        case .vnc: "VNC"
        }
    }
}
