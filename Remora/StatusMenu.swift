import AppKit

/// The menu bar icon and its menu, present while Remora runs. The menu lists the open tabs, then the app items.
/// It is built each time it opens, so it costs nothing while closed.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let sessionTabs: SessionTabs
    private let onOpen: () -> Void
    private let onShowTab: (UUID) -> Void
    private let onShowSettings: () -> Void
    private static let dotConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)

    init(
        sessionTabs: SessionTabs,
        onOpen: @escaping () -> Void,
        onShowTab: @escaping (UUID) -> Void,
        onShowSettings: @escaping () -> Void
    ) {
        self.sessionTabs = sessionTabs
        self.onOpen = onOpen
        self.onShowTab = onShowTab
        self.onShowSettings = onShowSettings
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Remora")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let tabs = sessionTabs.tabs
        if tabs.isEmpty { menu.addItem(withTitle: "No Sessions", action: nil, keyEquivalent: "") }
        for tab in tabs { menu.addItem(sessionItem(for: tab)) }
        menu.addItem(.separator())
        addItem("Open Remora", #selector(open(_:)), to: menu)
        menu.addItem(.separator())
        addItem("Settings…", #selector(showSettings(_:)), key: ",", to: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Remora", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            .target = NSApplication.shared
    }

    /// The tab's name and state, with a submenu of the actions that apply to it.
    private func sessionItem(for tab: SessionTabs.Tab) -> NSMenuItem {
        let item = NSMenuItem(title: tab.title, action: nil, keyEquivalent: "")
        item.subtitle = tab.state.statusTitle
        item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(Self.dotConfiguration.applying(.init(paletteColors: [tab.state.statusColor])))
        // The dot carries the session state, so it shows even where macOS hides menu item images.
        if #available(macOS 27, *) { item.preferredImageVisibility = .visible }
        let submenu = NSMenu()
        addItem("Show", #selector(showTab(_:)), for: tab.id, to: submenu)
        if tab.state.isLive {
            submenu.addItem(.separator())
            addItem("Disconnect", #selector(disconnect(_:)), for: tab.id, to: submenu)
        }
        item.submenu = submenu
        return item
    }

    private func addItem(_ title: String, _ action: Selector, key: String = "", for id: UUID? = nil, to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        item.representedObject = id
    }

    @objc private func open(_ sender: NSMenuItem) { onOpen() }
    @objc private func showSettings(_ sender: NSMenuItem) { onShowSettings() }

    @objc private func showTab(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onShowTab(id)
    }

    @objc private func disconnect(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        sessionTabs.disconnect(id)
    }
}
