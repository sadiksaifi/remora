import AppKit
import Observation
import RemoraCore
import SwiftUI

/// The list of saved connections and every action on them: connect, disconnect, add, edit, duplicate, delete.
@MainActor
final class ConnectionsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate, NSMenuItemValidation {
    private let connectionStore: ConnectionStore
    private let credentialStore: CredentialStore
    private let sessionTabs: SessionTabs
    private let tableView = ConnectionsTableView()
    private var emptyStateView: NSHostingView<EmptyStateView>!
    private var editorController: NSViewController?
    /// The visible connections: filtered by `searchText` and sorted by name.
    private var rows: [Connection] = []

    var searchText = "" {
        didSet { reloadRows() }
    }

    init(connectionStore: ConnectionStore, credentialStore: CredentialStore, sessionTabs: SessionTabs) {
        self.connectionStore = connectionStore
        self.credentialStore = credentialStore
        self.sessionTabs = sessionTabs
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(connectionStore:credentialStore:sessionTabs:)")
    }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("connection"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = 44
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openClickedRow(_:))
        tableView.onReturn = { [weak self] in self?.connect(nil) }
        tableView.menu = contextMenu()
        tableView.setAccessibilityLabel("Connections")
        tableView.setAccessibilityIdentifier("connectionsTable")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyStateView = NSHostingView(rootView: EmptyStateView(kind: .noConnections) { [weak self] in
            self?.newConnection(nil)
        })
        emptyStateView.sizingOptions = []
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView()
        view.addSubview(scrollView)
        view.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyStateView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeConnections()
        observeSessions()
    }

    var initialFirstResponder: NSView {
        tableView
    }

    /// Re-renders relative "last connected" dates, which go stale while the window sits open.
    func refreshDates() {
        reconfigureRows()
    }

    private func reconfigureRows() {
        guard tableView.numberOfRows > 0 else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integersIn: 0..<tableView.numberOfRows),
            columnIndexes: [0]
        )
    }

    // MARK: Actions

    @objc func newConnection(_ sender: Any?) {
        presentEditor(title: "New Connection", for: Connection(name: "", host: "", username: ""), password: "")
    }

    /// Opens each target in a tab, or shows its tab. From the context menu it applies only
    /// to rows without a live session.
    @objc func connect(_ sender: Any?) {
        var targets = targetRows(for: sender).map { rows[$0] }
        if isContextMenuItem(sender) {
            targets.removeAll { hasLiveSession($0) }
        }
        open(targets)
    }

    @objc func showSessionTab(_ sender: Any?) {
        open(targetRows(for: sender).map { rows[$0] }.filter(hasSessionTab))
    }

    @objc func disconnect(_ sender: Any?) {
        for connection in targetRows(for: sender).map({ rows[$0] }) where hasLiveSession(connection) {
            sessionTabs.disconnect(connection.id)
        }
    }

    @objc func editConnection(_ sender: Any?) {
        guard let connection = singleTarget(for: sender),
              let password = storedPassword(for: connection)
        else { return }
        presentEditor(title: "Edit Connection", for: connection, password: password)
    }

    @objc func duplicateConnection(_ sender: Any?) {
        guard let connection = singleTarget(for: sender),
              let password = storedPassword(for: connection)
        else { return }
        var copy = connection
        copy.id = UUID()
        copy.name += " copy"
        copy.lastConnected = nil
        presentEditor(title: "Duplicate Connection", for: copy, password: password)
    }

    @objc func delete(_ sender: Any?) {
        let targets = targetRows(for: sender).map { rows[$0] }
        guard let window = hostWindow, let first = targets.first else { return }
        let alert = NSAlert()
        if targets.count == 1 {
            alert.messageText = "Delete “\(first.name)”?"
            alert.informativeText = "This also removes its saved password. You can’t undo this action."
        } else {
            alert.messageText = "Delete \(targets.count) Connections?"
            alert.informativeText = "This also removes their saved passwords. You can’t undo this action."
        }
        let deleteButton = alert.addButton(withTitle: "Delete")
        deleteButton.hasDestructiveAction = true
        deleteButton.setAccessibilityIdentifier("deleteConfirm")
        alert.addButton(withTitle: "Cancel").setAccessibilityIdentifier("deleteCancel")
        alert.window.setAccessibilityIdentifier("deleteConfirmation")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.deleteConnections(ids: Set(targets.map(\.id)))
        }
    }

    /// Connects the double-clicked row, or shows its tab.
    @objc private func openClickedRow(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        open([rows[row]])
    }

    /// The hover button reads Disconnect for a live session and Connect otherwise.
    @objc private func actionButtonClicked(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < rows.count else { return }
        if hasLiveSession(rows[row]) {
            sessionTabs.disconnect(rows[row].id)
        } else {
            open([rows[row]])
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(connect(_:)):
            isContextMenuItem(menuItem)
                ? targetRows(for: menuItem).contains { !hasLiveSession(rows[$0]) }
                : !targetRows(for: menuItem).isEmpty
        case #selector(showSessionTab(_:)):
            targetRows(for: menuItem).contains { hasSessionTab(rows[$0]) }
        case #selector(disconnect(_:)):
            targetRows(for: menuItem).contains { hasLiveSession(rows[$0]) }
        case #selector(delete(_:)):
            !targetRows(for: menuItem).isEmpty
        case #selector(editConnection(_:)), #selector(duplicateConnection(_:)):
            targetRows(for: menuItem).count == 1
        default:
            true
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ConnectionCellView.identifier, owner: self)
            as? ConnectionCellView ?? makeCell()
        cell.configure(
            with: rows[row], session: sessionTabs.states[rows[row].id],
            hovered: row == self.tableView.hoveredRow
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        rows[row].name
    }

    private func makeCell() -> ConnectionCellView {
        let cell = ConnectionCellView()
        cell.actionButton.target = self
        cell.actionButton.action = #selector(actionButtonClicked(_:))
        return cell
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Connect", action: #selector(connect(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Show Tab", action: #selector(showSessionTab(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Disconnect", action: #selector(disconnect(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Edit…", action: #selector(editConnection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Duplicate", action: #selector(duplicateConnection(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete", action: #selector(delete(_:)), keyEquivalent: "")
        for item in menu.items {
            item.target = self
        }
        return menu
    }

    /// Shows only the session actions that apply to at least one target row.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            switch item.action {
            case #selector(connect(_:)), #selector(showSessionTab(_:)), #selector(disconnect(_:)):
                item.isHidden = !validateMenuItem(item)
            default:
                break
            }
        }
    }

    /// Context menu actions apply to the clicked row, or to the whole selection when the clicked
    /// row is part of it. Every other sender acts on the selection.
    private func targetRows(for sender: Any?) -> IndexSet {
        let selection = tableView.selectedRowIndexes
        guard let item = sender as? NSMenuItem, item.menu === tableView.menu else { return selection }
        let clicked = tableView.clickedRow
        guard clicked >= 0 else { return [] }
        return selection.contains(clicked) ? selection : [clicked]
    }

    private func isContextMenuItem(_ sender: Any?) -> Bool {
        (sender as? NSMenuItem)?.menu === tableView.menu
    }

    private func hasSessionTab(_ connection: Connection) -> Bool {
        sessionTabs.states[connection.id] != nil
    }

    private func hasLiveSession(_ connection: Connection) -> Bool {
        sessionTabs.states[connection.id]?.isLive ?? false
    }

    /// The main window, also while a session tab shows instead of this list.
    private var hostWindow: NSWindow? {
        parent?.view.window ?? view.window
    }

    /// Sheets attach to the window's content, which stays in the window on every page.
    private var presenter: NSViewController {
        parent ?? self
    }

    private func singleTarget(for sender: Any?) -> Connection? {
        let targets = targetRows(for: sender)
        guard targets.count == 1, let row = targets.first else { return nil }
        return rows[row]
    }

    // MARK: Store

    private func observeConnections() {
        withObservationTracking {
            _ = connectionStore.connections
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.reloadRows()
                self?.observeConnections()
            }
        }
        reloadRows()
    }

    private func observeSessions() {
        withObservationTracking {
            _ = sessionTabs.states
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.reconfigureRows()
                self?.observeSessions()
            }
        }
    }

    private func reloadRows() {
        let selectedIDs = Set(tableView.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].id : nil })
        let query = searchText.trimmingCharacters(in: .whitespaces)
        rows = connectionStore.connections
            .filter { $0.matches(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        tableView.reloadData()
        tableView.selectRowIndexes(
            IndexSet(rows.indices.filter { selectedIDs.contains(rows[$0].id) }),
            byExtendingSelection: false
        )
        tableView.updateHover()

        if connectionStore.connections.isEmpty {
            emptyStateView.rootView.kind = .noConnections
            emptyStateView.setAccessibilityIdentifier("noConnections")
        } else if rows.isEmpty {
            emptyStateView.rootView.kind = .noResults(query)
            emptyStateView.setAccessibilityIdentifier("noSearchResults")
        }
        emptyStateView.isHidden = !rows.isEmpty
        // Stripes fill the empty area below the rows, but would run through the empty state's text.
        tableView.usesAlternatingRowBackgroundColors = !rows.isEmpty
    }

    private func select(id: UUID) {
        reloadRows()
        guard let row = rows.firstIndex(where: { $0.id == id }) else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        view.window?.makeFirstResponder(tableView)
    }

    /// Opens or shows each connection's tab and records when a new session started.
    func open(_ connections: [Connection]) {
        var failure: (any Error)?
        for connection in connections where sessionTabs.open(connection) {
            do {
                try connectionStore.markConnected(id: connection.id)
            } catch {
                failure = error
            }
        }
        if let failure {
            showAlert("Couldn’t Save Connection", error: failure, on: hostWindow)
        }
    }

    private func storedPassword(for connection: Connection) -> String? {
        do {
            return try credentialStore.password(for: connection.id) ?? ""
        } catch {
            showAlert("Couldn’t Read Password", error: error, on: hostWindow)
            return nil
        }
    }

    /// Saves the connection, then its password. Safe to retry after a partial failure.
    private func save(_ connection: Connection, password: String) {
        do {
            if connectionStore.connections.contains(where: { $0.id == connection.id }) {
                try connectionStore.update(connection)
            } else {
                try connectionStore.add(connection)
            }
            if password.isEmpty {
                try credentialStore.removePassword(for: connection.id)
            } else {
                try credentialStore.setPassword(password, for: connection.id)
            }
        } catch {
            showAlert("Couldn’t Save Connection", error: error, on: editorController?.view.window ?? hostWindow)
            return
        }
        sessionTabs.update(connection)
        dismissEditor()
        select(id: connection.id)
    }

    private func deleteConnections(ids: Set<UUID>) {
        do {
            try connectionStore.delete(ids: ids)
            for id in ids {
                try credentialStore.removePassword(for: id)
            }
        } catch {
            showAlert("Couldn’t Delete Connection", error: error, on: hostWindow)
        }
    }

    // MARK: Presentation

    private func presentEditor(title: String, for connection: Connection, password: String) {
        guard editorController == nil else { return }
        let editor = ConnectionEditor(
            title: title,
            connection: connection,
            password: password,
            onCancel: { [weak self] in self?.dismissEditor() },
            onSave: { [weak self] connection, password in self?.save(connection, password: password) }
        )
        let controller = NSHostingController(rootView: editor)
        controller.sizingOptions = .preferredContentSize
        editorController = controller
        presenter.presentAsSheet(controller)
    }

    private func dismissEditor() {
        guard let editorController else { return }
        presenter.dismiss(editorController)
        self.editorController = nil
    }

    private func showAlert(_ title: String, error: any Error, on window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = Self.message(for: error)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case let ConnectionStore.StorageError.loadFailed(_, underlying),
             let ConnectionStore.StorageError.quarantineFailed(_, underlying),
             let ConnectionStore.StorageError.saveFailed(_, underlying):
            underlying.localizedDescription
        default:
            error.localizedDescription
        }
    }
}

extension Connection {
    /// True when the name, host, or username contains the query. An empty query matches everything.
    func matches(_ query: String) -> Bool {
        query.isEmpty
            || name.localizedStandardContains(query)
            || host.localizedStandardContains(query)
            || username.localizedStandardContains(query)
    }
}

/// Shown in place of the list when there is nothing to list.
struct EmptyStateView: View {
    enum Kind: Equatable {
        case noConnections
        case noResults(String)
    }

    var kind: Kind
    let addConnection: () -> Void

    var body: some View {
        switch kind {
        case .noConnections:
            ContentUnavailableView {
                Label("No Connections", systemImage: "desktopcomputer")
            } description: {
                Text("Add a computer to connect to it.")
            } actions: {
                Button("Add Connection", action: addConnection)
                    .accessibilityIdentifier("addConnection")
            }
        case .noResults(let query):
            ContentUnavailableView.search(text: query)
        }
    }
}
