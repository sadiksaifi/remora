import AppKit
import Observation
import RemoraCore

/// Placeholder connection list. The connection editor and session actions belong here.
@MainActor
final class ConnectionsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    private let connectionStore: ConnectionStore
    private let credentialStore: CredentialStore
    private let tableView = NSTableView()

    init(connectionStore: ConnectionStore, credentialStore: CredentialStore) {
        self.connectionStore = connectionStore
        self.credentialStore = credentialStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(connectionStore:credentialStore:)")
    }

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(nameColumn)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeConnections()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        connectionStore.connections.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: connectionStore.connections[row].name)
    }

    func newConnection(_ sender: Any?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "New Connection"
        alert.informativeText = "The connection editor is coming soon."
        alert.beginSheetModal(for: window)
    }

    @objc func delete(_ sender: Any?) {
        let ids = Set(tableView.selectedRowIndexes.map { connectionStore.connections[$0].id })
        guard !ids.isEmpty else { return }
        do {
            for id in ids {
                try credentialStore.removePassword(for: id)
            }
            try connectionStore.delete(ids: ids)
        } catch {
            presentError(error)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(delete(_:)) || tableView.numberOfSelectedRows > 0
    }

    private func observeConnections() {
        withObservationTracking {
            _ = connectionStore.connections
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.tableView.reloadData()
                self?.observeConnections()
            }
        }
        tableView.reloadData()
    }
}
