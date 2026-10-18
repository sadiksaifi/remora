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
    private let tabStripLayout = SessionTabStripLayout()
    private let tabStripWidth: NSLayoutConstraint
    private let searchToolbarItem = NSSearchToolbarItem(itemIdentifier: MainWindowController.searchItem)
    private let searchWidth: NSLayoutConstraint
    /// Window > a separator and tab 1 through 9, hidden past the last tab.
    private(set) var tabMenuItems: [NSMenuItem] = []
    private var eventMonitor: Any?

    init(connectionStore: ConnectionStore, credentialStore: CredentialStore, sessionTabs: SessionTabs) {
        self.connectionStore = connectionStore
        self.sessionTabs = sessionTabs
        connectionsViewController = ConnectionsViewController(
            connectionStore: connectionStore,
            credentialStore: credentialStore,
            sessionTabs: sessionTabs
        )
        currentPage = connectionsViewController
        tabStrip = NSHostingView(rootView: SessionTabStrip(tabs: sessionTabs, layout: tabStripLayout))
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
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) {
            [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consume(event) ?? false }
            return consumed ? nil : event
        }
        observeTabs()
        updateChrome()
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(connectionStore:credentialStore:sessionTabs:)")
    }

    isolated deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    /// Handles the secondary clicks that the toolbar would otherwise take.
    /// Returns true for an event it consumed.
    private func consume(_ event: NSEvent) -> Bool {
        switch event.type {
        case .rightMouseDown:
            showTabMenu(for: event)
        case .leftMouseDown where event.modifierFlags.contains(.control):
            showTabMenu(for: event)
        default:
            false
        }
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

    func select(_ id: UUID?) {
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

    @objc func takeOverAgentControl(_ sender: Any?) {
        guard let session = targetSession(sender) else { return }
        Task { do { try await session.handoverAgentControl(stopping: false) } catch { NSApp.presentError(error) } }
    }
    @objc func resumeAgentControl(_ sender: Any?) {
        do { try targetSession(sender)?.resumeAgentControl() } catch { NSApp.presentError(error) }
    }
    @objc func stopAgentControl(_ sender: Any?) {
        guard let session = targetSession(sender) else { return }
        Task { do { try await session.handoverAgentControl(stopping: true) } catch { NSApp.presentError(error) } }
    }
    @objc func stopAllAgentControl(_ sender: Any?) {
        let targets = sessionTabs.tabs.compactMap { sessionTabs.session(for: $0.id) }
        Task {
            for session in targets {
                do { try await session.handoverAgentControl(stopping: true) } catch { NSApp.presentError(error) }
            }
        }
    }

    @objc func disconnectSession(_ sender: Any?) { sessionTabs.selectedSession?.disconnectSession() }
    @objc func reconnectSession(_ sender: Any?) { sessionTabs.selectedSession?.reconnect() }
    @objc func sendCtrlAltDelete(_ sender: Any?) { sessionTabs.selectedSession?.sendCtrlAltDelete() }
    @objc func releaseKeyboardCapture(_ sender: Any?) { sessionTabs.selectedSession?.releaseKeyboardCapture() }
    @objc func takeScreenshot(_ sender: Any?) { targetSession(sender)?.captureScreenshot(copyToClipboard: false) }
    @objc func copyScreenshot(_ sender: Any?) { targetSession(sender)?.captureScreenshot(copyToClipboard: true) }
    @objc func toggleRecording(_ sender: Any?) { targetSession(sender)?.toggleRecording() }

    /// Take Screenshot, Copy Screenshot, and Start Recording, for the Session menu and the tab actions menu.
    /// Copy Screenshot is a visible item, because an alternate would only show while holding all four modifiers.
    /// Validation retitles the recording item while a recording runs or finishes.
    static func makeCaptureItems() -> [NSMenuItem] {
        let chord: NSEvent.ModifierFlags = [.control, .option, .command]
        let take = NSMenuItem(title: "Take Screenshot", action: #selector(takeScreenshot(_:)), keyEquivalent: "s")
        take.keyEquivalentModifierMask = chord
        let copy = NSMenuItem(title: "Copy Screenshot", action: #selector(copyScreenshot(_:)), keyEquivalent: "s")
        copy.keyEquivalentModifierMask = chord.union(.shift)
        let record = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording(_:)), keyEquivalent: "r")
        record.keyEquivalentModifierMask = chord
        return [take, copy, record]
    }

    /// An item from a tab's own menu names its tab. Other items act on the shown tab.
    private func targetSession(_ sender: Any?) -> SessionViewController? {
        if let id = (sender as? NSMenuItem)?.representedObject as? UUID { return sessionTabs.session(for: id) }
        return sessionTabs.selectedSession
    }

    /// From the tab's accessibility action and its menu. Only the shown tab's desktop can take the keyboard.
    private func setKeyboardCapture(_ id: UUID, captured: Bool) {
        guard let session = sessionTabs.session(for: id) else { return }
        if captured { session.focusDesktop() } else { session.releaseKeyboardCapture() }
    }

    @objc private func toggleTabKeyboardCapture(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let session = sessionTabs.session(for: id) else { return }
        setKeyboardCapture(id, captured: !session.hasKeyboard)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let session = targetSession(menuItem)
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
        case #selector(closeClickedTab(_:)):
            return canChangeTabs
        case #selector(toggleTabKeyboardCapture(_:)):
            menuItem.state = session?.hasKeyboard == true ? .on : .off
            return session?.isConnected == true && session === sessionTabs.selectedSession
        case #selector(takeOverAgentControl(_:)): return session?.control.canTakeOver == true
        case #selector(resumeAgentControl(_:)): return session?.control.canResume == true
        case #selector(stopAgentControl(_:)): return session?.control.canStop == true
        case #selector(stopAllAgentControl(_:)):
            return sessionTabs.tabs.contains { sessionTabs.session(for: $0.id)?.control.canStop == true }
        case #selector(disconnectSession(_:)):
            return session?.canDisconnect ?? false
        case #selector(reconnectSession(_:)):
            return session?.canReconnect ?? false
        case #selector(sendCtrlAltDelete(_:)):
            return session?.isConnected == true && session?.control.allowsHumanInput == true
        case #selector(releaseKeyboardCapture(_:)):
            return session?.hasKeyboard ?? false
        case #selector(takeScreenshot(_:)), #selector(copyScreenshot(_:)):
            return session?.isConnected ?? false
        case #selector(toggleRecording(_:)):
            switch session?.capture.recordingState {
            case .recording:
                menuItem.title = "Stop Recording"
                return true
            case .finishing:
                menuItem.title = "Finishing Recording\u{2026}"
                return false
            default:
                menuItem.title = "Start Recording"
                return session?.isConnected ?? false
            }
        default:
            return true
        }
    }

    /// The toolbar takes secondary clicks for its own menu before the strip's views see them.
    private func showTabMenu(for event: NSEvent) -> Bool {
        guard event.window != nil, event.window === tabStrip.window, !tabStrip.isHiddenOrHasHiddenAncestor else {
            return false
        }
        let point = tabStrip.convert(event.locationInWindow, from: nil)
        guard tabStrip.bounds.contains(point), let id = tabStripLayout.tab(at: point) else { return false }
        NSMenu.popUpContextMenu(tabMenu(for: id, includingActions: false), with: event, for: tabStrip)
        return true
    }

    /// Hangs the tab's menu under its actions button, centered like Safari's page menu. AppKit has no
    /// public menu with an arrow, so it is a plain pop-up menu. `button` is in the strip's flipped coordinates.
    private func showTabActions(for id: UUID, below button: CGRect) {
        let menu = tabMenu(for: id, includingActions: true)
        menu.popUp(positioning: nil, at: NSPoint(x: button.midX - menu.size.width / 2, y: button.maxY + 6), in: tabStrip)
    }

    /// The context menu has the tab items. The menu button's menu puts Capture Keyboard and the
    /// capture items first.
    private func tabMenu(for id: UUID, includingActions: Bool) -> NSMenu {
        let menu = NSMenu()
        if includingActions {
            let keyboard = menu.addItem(withTitle: "Capture Keyboard", action: #selector(toggleTabKeyboardCapture(_:)), keyEquivalent: "")
            keyboard.target = self
            keyboard.representedObject = id
            menu.addItem(.separator())
            for item in Self.makeCaptureItems() {
                item.target = self
                item.representedObject = id
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let close = menu.addItem(withTitle: "Close Tab", action: #selector(closeClickedTab(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = id
        return menu
    }

    @objc private func closeClickedTab(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        close(id)
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
        let field = searchToolbarItem.searchField
        field.stringValue = ""
        searchToolbarItem.endSearchInteraction()
        if field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
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

    /// On a session tab, Escape clears and closes the search and gives the keyboard back to the desktop.
    /// While suggestions show, the field gives the first Escape to them, and they only close.
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
        homeToolbarItem.view = toolbarButton("house", "Connections", action: #selector(showHome(_:)), identifier: "home")
        homeToolbarItem.label = "Connections"
        homeToolbarItem.toolTip = "Show Connections"

        tabStrip.rootView = SessionTabStrip(
            tabs: sessionTabs,
            layout: tabStripLayout,
            onSelect: { [weak self] id in self?.select(id) },
            onClose: { [weak self] id in self?.close(id) },
            onStopRecording: { [weak self] id in
                guard let session = self?.sessionTabs.session(for: id) else { return }
                Task { await session.stopRecording() }
            },
            onShowActions: { [weak self] id, button in self?.showTabActions(for: id, below: button) },
            onSetKeyboardCapture: { [weak self] id, captured in self?.setKeyboardCapture(id, captured: captured) }
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
        field.setAccessibilityIdentifier("connectionsSearch")
        field.placeholderString = "Search"
        field.target = self
        field.action = #selector(searchChanged(_:))
        field.delegate = self
        searchToolbarItem.preferredWidthForSearchField = Self.expandedSearchWidth
        // Below the item's own constraints, so the field still expands while it has the keyboard.
        searchWidth.priority = .init(500)
        searchWidth.isActive = true
    }

    /// Looks like a bordered image item. Unlike one, it can carry an accessibility identifier.
    private func toolbarButton(_ symbol: String, _ description: String, action: Selector, identifier: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: description)!,
                              target: self, action: action)
        button.bezelStyle = .toolbar
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.homeItem, .flexibleSpace, Self.tabsItem, .flexibleSpace,
            Self.newConnectionItem, Self.searchItem,
        ]
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
            item.view = toolbarButton("plus", "New Connection", action: #selector(newConnection(_:)), identifier: "newConnection")
            item.label = "New Connection"
            item.toolTip = "New Connection"
            return item
        case Self.searchItem:
            return searchToolbarItem
        default:
            return nil
        }
    }
}
