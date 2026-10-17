import AppKit

/// Inset connection table that tracks the row under the pointer and connects on Return.
@MainActor
final class ConnectionsTableView: NSTableView {
    var onReturn: (() -> Void)?
    private(set) var hoveredRow = -1
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard let clipView = superview as? NSClipView else { return }
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHover()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredRow(-1)
    }

    /// A click in the list takes the keyboard from the toolbar's search field, which then
    /// collapses when it is empty. A click on a cell's label would otherwise leave the keyboard there.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        row(at: convert(event.locationInWindow, from: nil)) >= 0 ? super.menu(for: event) : nil
    }

    override func keyDown(with event: NSEvent) {
        let returnKey: UInt16 = 36
        let enterKey: UInt16 = 76
        if event.keyCode == returnKey || event.keyCode == enterKey, let onReturn {
            onReturn()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Recomputes the hovered row from the current pointer location, for example after a reload.
    func updateHover() {
        guard let window, window.isVisible else {
            setHoveredRow(-1)
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHoveredRow(visibleRect.contains(point) ? row(at: point) : -1)
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        updateHover()
    }

    private func setHoveredRow(_ row: Int) {
        guard row != hoveredRow else { return }
        cellView(atRow: hoveredRow)?.isHovered = false
        hoveredRow = row
        cellView(atRow: row)?.isHovered = true
    }

    private func cellView(atRow row: Int) -> ConnectionCellView? {
        guard row >= 0, row < numberOfRows else { return nil }
        return view(atColumn: 0, row: row, makeIfNecessary: false) as? ConnectionCellView
    }
}
