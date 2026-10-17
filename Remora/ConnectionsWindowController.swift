import AppKit
import RemoraCore

@MainActor
final class ConnectionsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private static let newConnectionItem = NSToolbarItem.Identifier("newConnection")
    private static let searchItem = NSToolbarItem.Identifier("search")

    private let connectionsViewController: ConnectionsViewController
    private let searchToolbarItem = NSSearchToolbarItem(itemIdentifier: ConnectionsWindowController.searchItem)

    init(connectionStore: ConnectionStore, credentialStore: CredentialStore, sessionWindows: SessionWindows) {
        connectionsViewController = ConnectionsViewController(
            connectionStore: connectionStore,
            credentialStore: credentialStore,
            sessionWindows: sessionWindows
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Remora"
        window.minSize = NSSize(width: 380, height: 300)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = connectionsViewController
        window.setContentSize(NSSize(width: 560, height: 440))
        window.center()
        super.init(window: window)
        shouldCascadeWindows = false
        window.setFrameAutosaveName("Connections")
        window.delegate = self

        searchToolbarItem.searchField.placeholderString = "Search"
        searchToolbarItem.searchField.target = self
        searchToolbarItem.searchField.action = #selector(searchChanged(_:))

        let toolbar = NSToolbar(identifier: "Connections")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.allowsDisplayModeCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.initialFirstResponder = connectionsViewController.initialFirstResponder
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(connectionStore:credentialStore:sessionWindows:)")
    }

    @objc func newConnection(_ sender: Any?) {
        connectionsViewController.newConnection(sender)
    }

    @objc func startSearch(_ sender: Any?) {
        searchToolbarItem.beginSearchInteraction()
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        connectionsViewController.searchText = sender.stringValue
    }

    func windowDidBecomeKey(_ notification: Notification) {
        connectionsViewController.refreshDates()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.newConnectionItem, Self.searchItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.newConnectionItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Connection")
            item.label = "New Connection"
            item.toolTip = "New Connection"
            item.isBordered = true
            item.target = self
            item.action = #selector(newConnection(_:))
            return item
        case Self.searchItem:
            return searchToolbarItem
        default:
            return nil
        }
    }
}
