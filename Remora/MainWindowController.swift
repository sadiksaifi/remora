import AppKit
import RemoraCore
import SwiftUI

/// The app's only window. Home shows the connections list; each session shows as a tab in the toolbar.
/// Native window tabbing is off, so window managers see exactly one window.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate,
    NSMenuItemValidation, NSTextSuggestionsDelegate {
    typealias SuggestionItemType = UUID

    private static let homeItem = NSToolbarItem.Identifier("home")
    private static let tabsItem = NSToolbarItem.Identifier("tabs")
    private static let newConnectionItem = NSToolbarItem.Identifier("newConnection")
    private static let searchItem = NSToolbarItem.Identifier("search")
    /// Narrower than the search field's minimum, so the toolbar shows the collapsed search button.
    private static let collapsedSearchWidth: CGFloat = 30
    private static let expandedSearchWidth: CGFloat = 240

    private let connectionStore: ConnectionStore
    private let sessionTabs: SessionTabs
    private let connectionsViewController: ConnectionsViewController
    /// Holds the shown page: the connections list or one session tab.
    private let pageViewController = NSViewController()
    private var currentPage: NSViewController
    private let homeToolbarItem = NSToolbarItem(itemIdentifier: MainWindowController.homeItem)
    private let tabsToolbarItem = NSToolbarItem(itemIdentifier: MainWindowController.tabsItem)
    private let tabStrip: NSHostingView<SessionTabStrip>
    private let tabStripWidth: NSLayoutConstraint
    private let searchToolbarItem = NSSearchToolbarItem(itemIdentifier: MainWindowController.searchItem)
    private let searchWidth: NSLayoutConstraint
    /// Window > a separator and tab 1 through 9, hidden past the last tab.
    private(set) var tabMenuItems: [NSMenuItem] = []

    init(connectionStore: ConnectionStore, credentialStore: CredentialStore, sessionTabs: SessionTabs) {
        self.connectionStore = connectionStore
        self.sessionTabs = sessionTabs
        connectionsViewController = ConnectionsViewController(
            connectionStore: connectionStore,
            credentialStore: credentialStore,
            sessionTabs: sessionTabs
        )
        currentPage = connectionsViewController
        tabStrip = NSHostingView(rootView: SessionTabStrip(tabs: sessionTabs))
        tabStripWidth = tabStrip.widthAnchor.constraint(
            lessThanOrEqualToConstant: SessionTabStrip.idealWidth(forTabCount: 1)
        )
        searchWidth = searchToolbarItem.searchField.widthAnchor.constraint(equalToConstant: Self.collapsedSearchWidth)
        let size = NSSize(width: 960, height: 640)
        pageViewController.view = NSView(frame: NSRect(origin: .zero, size: size))
        // No full-size content view: with the content under the toolbar, AppKit shows the toolbar
        // background only while the pointer is in the title bar. Below it, the background always shows.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Connections"
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentViewController = pageViewController
        window.setContentSize(size)
        super.init(window: window)
        shouldCascadeWindows = false
        window.delegate = self
        pageViewController.addChild(connectionsViewController)
        embed(connectionsViewController.view)

        configureToolbarItems()
        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.allowsDisplayModeCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        // Place the window only once the toolbar has its height. A frame restored earlier grows
        // when the toolbar attaches, and Zoom then treats the pre-toolbar frame as the user's size.
        window.center()
        window.setFrameAutosaveName("Connections")
        window.initialFirstResponder = connectionsViewController.initialFirstResponder

        tabMenuItems = [.separator()] + (1...9).map { number in
            let item = NSMenuItem(title: "Tab \(number)", action: #selector(showTab(_:)), keyEquivalent: "\(number)")
            item.keyEquivalentModifierMask = [.control, .option, .command]
            item.tag = number - 1
            item.target = self
            item.isHidden = true
            return item
        }
        sessionTabs.onSelectionChange = { [weak self] _, selection in self?.showPage(selection) }
        observeTabs()
        updateChrome()
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(connectionStore:credentialStore:sessionTabs:)")
    }

    // MARK: Pages

    private func embed(_ view: NSView) {
        view.frame = pageViewController.view.bounds
        view.autoresizingMask = [.width, .height]
        pageViewController.view.addSubview(view)
    }

    /// Swaps the shown page. A hidden session's desktop leaves the window, which stops its rendering,
    /// keyboard capture, and pressed keys and buttons.
    private func showPage(_ selection: UUID?) {
        let page: NSViewController = selection.flatMap { sessionTabs.session(for: $0) } ?? connectionsViewController
        guard page !== currentPage else { return }
        resetSearch()
        currentPage.view.removeFromSuperview()
        if page.parent == nil { pageViewController.addChild(page) }
        embed(page.view)
        currentPage = page
        window?.contentView?.layoutSubtreeIfNeeded()
        updateChrome()
        if let session = page as? SessionViewController {
            session.didShow()
        } else {
            window?.makeFirstResponder(connectionsViewController.initialFirstResponder)
        }
    }

    /// Tab changes wait while a sheet is open, so a sheet never belongs to a hidden tab.
    private var canChangeTabs: Bool {
        window?.attachedSheet == nil
    }

    private func select(_ id: UUID?) {
        guard canChangeTabs else { return }
        sessionTabs.select(id)
    }

    private func close(_ id: UUID) {
        guard canChangeTabs else { return }
        sessionTabs.close(id)
    }

    private func observeTabs() {
        withObservationTracking {
            _ = sessionTabs.tabs
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateChrome()
                self?.observeTabs()
            }
        }
    }

    /// Shows the Home button and tab strip only while tabs are open. The strip replaces the visible title,
    /// and the window title names the shown page for the Window menu and accessibility.
    private func updateChrome() {
        guard let window else { return }
        let tabs = sessionTabs.tabs
        homeToolbarItem.isHidden = tabs.isEmpty
        tabsToolbarItem.isHidden = tabs.isEmpty
        window.titleVisibility = tabs.isEmpty ? .visible : .hidden
        window.title = tabs.first { $0.id == sessionTabs.selection }?.title ?? "Connections"
        tabStripWidth.constant = SessionTabStrip.idealWidth(forTabCount: tabs.count)
        searchToolbarItem.searchField.suggestionsDelegate = currentPage is SessionViewController ? self : nil
        for item in tabMenuItems {
            if item.isSeparatorItem {
                item.isHidden = tabs.isEmpty
            } else {
                item.isHidden = !tabs.indices.contains(item.tag)
                if tabs.indices.contains(item.tag) { item.title = tabs[item.tag].title }
            }
        }
    }

    // MARK: Actions

    @objc func newConnection(_ sender: Any?) {
        connectionsViewController.newConnection(sender)
    }

    @objc func startSearch(_ sender: Any?) {
        searchWidth.constant = Self.expandedSearchWidth
        searchToolbarItem.beginSearchInteraction()
    }

    @objc func showHome(_ sender: Any?) {
        select(nil)
    }

    @objc func showPreviousTab(_ sender: Any?) {
        guard canChangeTabs else { return }
        sessionTabs.selectAdjacent(forward: false)
    }

    @objc func showNextTab(_ sender: Any?) {
        guard canChangeTabs else { return }
        sessionTabs.selectAdjacent(forward: true)
    }

    @objc func showTab(_ sender: NSMenuItem) {
        guard canChangeTabs else { return }
        sessionTabs.select(index: sender.tag)
    }

    @objc func closeTab(_ sender: Any?) {
        guard let selection = sessionTabs.selection else { return }
        close(selection)
    }

    @objc func disconnectSession(_ sender: Any?) { sessionTabs.selectedSession?.disconnectSession() }
    @objc func reconnectSession(_ sender: Any?) { sessionTabs.selectedSession?.reconnect() }
    @objc func sendCtrlAltDelete(_ sender: Any?) { sessionTabs.selectedSession?.sendCtrlAltDelete() }
    @objc func releaseKeyboardCapture(_ sender: Any?) { sessionTabs.selectedSession?.releaseKeyboardCapture() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let session = sessionTabs.selectedSession
        switch menuItem.action {
        case #selector(showHome(_:)):
            return canChangeTabs
        case #selector(showPreviousTab(_:)), #selector(showNextTab(_:)):
            return !sessionTabs.tabs.isEmpty && canChangeTabs
        case #selector(showTab(_:)):
            let tabs = sessionTabs.tabs
            menuItem.state = tabs.indices.contains(menuItem.tag) && tabs[menuItem.tag].id == sessionTabs.selection
                ? .on : .off
            return tabs.indices.contains(menuItem.tag) && canChangeTabs
        case #selector(closeTab(_:)):
            return session != nil && canChangeTabs
        case #selector(disconnectSession(_:)):
            return session?.canDisconnect ?? false
        case #selector(reconnectSession(_:)):
            return session?.canReconnect ?? false
        case #selector(sendCtrlAltDelete(_:)):
            return session?.isConnected ?? false
        case #selector(releaseKeyboardCapture(_:)):
            return session?.hasKeyboard ?? false
        default:
            return true
        }
    }

    // MARK: Search

    @objc private func searchChanged(_ sender: NSSearchField) {
        updateSearchWidth()
        // On a session tab the text only drives suggestions.
        if currentPage === connectionsViewController {
            connectionsViewController.searchText = sender.stringValue
        }
    }

    /// Keeps the field open while a filter is active on the connections list.
    private func updateSearchWidth() {
        let field = searchToolbarItem.searchField
        searchWidth.constant = field.stringValue.isEmpty && field.currentEditor() == nil
            ? Self.collapsedSearchWidth : Self.expandedSearchWidth
    }

    /// Clears the search and closes the field when the page changes.
    private func resetSearch() {
        let field = searchToolbarItem.searchField
        let editing = field.currentEditor() != nil
        field.stringValue = ""
        connectionsViewController.searchText = ""
        if editing { searchToolbarItem.endSearchInteraction() }
        updateSearchWidth()
    }

    /// Closes the search on a session tab and gives the keyboard back to the desktop.
    private func finishSessionSearch() {
        searchToolbarItem.searchField.stringValue = ""
        searchToolbarItem.endSearchInteraction()
        updateSearchWidth()
        sessionTabs.selectedSession?.focusDesktop()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        updateSearchWidth()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if currentPage !== connectionsViewController {
            searchToolbarItem.searchField.stringValue = ""
        }
        // Collapse once the field has given up the keyboard, unless a filter is active.
        Task { @MainActor [weak self] in
            guard let self, searchToolbarItem.searchField.currentEditor() == nil else { return }
            updateSearchWidth()
            if searchToolbarItem.searchField.stringValue.isEmpty { searchToolbarItem.endSearchInteraction() }
        }
    }

    /// On a session tab, Escape clears and closes the search in one step.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
              currentPage !== connectionsViewController else { return false }
        finishSessionSearch()
        return true
    }

    /// Saved connections matching the search, offered while a session tab shows.
    func textField(_ textField: NSTextField, provideUpdatedSuggestions responseHandler: @escaping (ItemResponse) -> Void) {
        let query = textField.stringValue.trimmingCharacters(in: .whitespaces)
        let matches = query.isEmpty ? [] : connectionStore.connections
            .filter { $0.matches(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var response = ItemResponse(items: matches.map { connection in
            var item = Item(representedValue: connection.id, title: connection.name)
            item.secondaryTitle = ConnectionCellView.subtitle(for: connection)
            item.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
            return item
        })
        response.phase = .final
        responseHandler(response)
    }

    /// Opens the chosen connection in a new tab, or shows its open tab.
    func textField(_ textField: NSTextField, didSelect item: Item) {
        let id = item.representedValue
        // Let the field finish its own handling of the choice first.
        Task { @MainActor [weak self] in
            guard let self, let connection = connectionStore.connections.first(where: { $0.id == id }) else { return }
            finishSessionSearch()
            connectionsViewController.open([connection])
        }
    }

    // MARK: Window

    func windowDidBecomeKey(_ notification: Notification) {
        connectionsViewController.refreshDates()
    }

    /// Closing the window disconnects every session, after asking while any is live.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let live = sessionTabs.liveCount
        guard live > 0 else {
            sessionTabs.closeAll()
            return true
        }
        let alert = NSAlert()
        alert.messageText = live == 1 ? "Disconnect 1 Session?" : "Disconnect \(live) Sessions?"
        alert.informativeText = "Closing the window ends every session in it."
        alert.addButton(withTitle: "Disconnect")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.sessionTabs.closeAll()
            sender?.close()
        }
        return false
    }

    /// The toolbar hides in full screen and slides in when the pointer reaches the top of the screen.
    func window(
        _ window: NSWindow,
        willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []
    ) -> NSApplication.PresentationOptions {
        proposedOptions.union([.fullScreen, .autoHideMenuBar, .autoHideToolbar])
    }

    func windowWillEnterFullScreen(_ notification: Notification) { sessionTabs.selectedSession?.windowWillTransition() }
    func windowWillExitFullScreen(_ notification: Notification) { sessionTabs.selectedSession?.windowWillTransition() }
    func windowDidEnterFullScreen(_ notification: Notification) { sessionTabs.selectedSession?.windowDidTransition() }
    func windowDidExitFullScreen(_ notification: Notification) { sessionTabs.selectedSession?.windowDidTransition() }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { sessionTabs.selectedSession?.windowDidTransition() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { sessionTabs.selectedSession?.windowDidTransition() }
    func windowDidEndLiveResize(_ notification: Notification) { sessionTabs.selectedSession?.windowDidChangeSize() }
    func windowDidChangeScreen(_ notification: Notification) { sessionTabs.selectedSession?.windowDidChangeSize() }

    // MARK: Toolbar

    private func configureToolbarItems() {
        homeToolbarItem.image = NSImage(systemSymbolName: "house", accessibilityDescription: "Connections")
        homeToolbarItem.label = "Connections"
        homeToolbarItem.toolTip = "Show Connections"
        homeToolbarItem.isBordered = true
        homeToolbarItem.target = self
        homeToolbarItem.action = #selector(showHome(_:))

        tabStrip.rootView = SessionTabStrip(
            tabs: sessionTabs,
            onSelect: { [weak self] id in self?.select(id) },
            onClose: { [weak self] id in self?.close(id) }
        )
        tabStrip.sizingOptions = []
        tabStrip.safeAreaRegions = []
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        // Flexible spaces on both sides center the strip. It grows to its ideal width, then shrinks to fit.
        NSLayoutConstraint.activate([
            tabStrip.heightAnchor.constraint(equalToConstant: SessionTabStrip.height),
            tabStrip.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            tabStripWidth,
        ])
        tabsToolbarItem.view = tabStrip
        tabsToolbarItem.label = "Tabs"
        tabsToolbarItem.visibilityPriority = .high

        let field = searchToolbarItem.searchField
        field.placeholderString = "Search"
        field.target = self
        field.action = #selector(searchChanged(_:))
        field.delegate = self
        searchToolbarItem.preferredWidthForSearchField = Self.expandedSearchWidth
        // Below the item's own constraints, so the field still expands while it has the keyboard.
        searchWidth.priority = .init(500)
        searchWidth.isActive = true
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.homeItem, .flexibleSpace, Self.tabsItem, .flexibleSpace, Self.newConnectionItem, Self.searchItem]
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
        case Self.homeItem:
            return homeToolbarItem
        case Self.tabsItem:
            return tabsToolbarItem
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
