import AppKit

/// The menu bar icon and its menu, present while Remora runs. The menu lists the open tabs, then the app items.
/// It is built each time it opens, so it costs nothing while closed.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let sessionTabs: SessionTabs
    /// Owns the agent control actions and their validation, which work while its window is closed.
    private let windowController: MainWindowController
    private let onOpen: () -> Void
    private let onShowTab: (UUID) -> Void
    private let onShowSettings: () -> Void
    private static let dotConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)

    init(
        sessionTabs: SessionTabs,
        windowController: MainWindowController,
        onOpen: @escaping () -> Void,
        onShowTab: @escaping (UUID) -> Void,
        onShowSettings: @escaping () -> Void
    ) {
        self.sessionTabs = sessionTabs
        self.windowController = windowController
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
        menu.addItem(
            withTitle: "Stop All Agent Control", action: #selector(MainWindowController.stopAllAgentControl(_:)),
            keyEquivalent: ""
        ).target = windowController
        menu.addItem(.separator())
        addItem("Settings…", #selector(showSettings(_:)), key: ",", to: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Remora", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            .target = NSApplication.shared
    }

    /// The tab's name, state and starter, with a submenu of the actions that apply to it.
    private func sessionItem(for tab: SessionTabs.Tab) -> NSMenuItem {
        let item = NSMenuItem(title: tab.title, action: nil, keyEquivalent: "")
        let state = tab.control == .paused ? "Paused" : tab.state.statusTitle
        item.subtitle = "\(state) · Started by \(sessionTabs.session(for: tab.id)?.startedBy ?? "you")"
        if tab.control == .idle {
            item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(Self.dotConfiguration.applying(.init(paletteColors: [tab.state.statusColor])))
        } else {
            item.tag = tab.control == .active ? Self.activeAgentTag : Self.inactiveAgentTag
            item.image = Self.agentMarker(item, highlighted: false)
            item.image?.accessibilityDescription = tab.control.agentStatus(tab.agentName)
        }
        // The image carries the session state, so it shows even where macOS hides menu item images.
        if #available(macOS 27, *) { item.preferredImageVisibility = .visible }
        let submenu = NSMenu()
        addItem("Show", #selector(showTab(_:)), for: tab.id, to: submenu)
        let agentItems = windowController.agentControlItems(for: tab.id, includingStopAll: false)
        if !agentItems.isEmpty { submenu.addItem(.separator()) }
        for agentItem in agentItems { submenu.addItem(agentItem) }
        if tab.state.isLive {
            submenu.addItem(.separator())
            addItem("Disconnect", #selector(disconnect(_:)), for: tab.id, to: submenu)
        }
        item.submenu = submenu
        return item
    }

    private static let activeAgentTag = 1
    private static let inactiveAgentTag = 2

    /// Blue while the agent has control, gray otherwise, and white on the highlighted row.
    private static func agentMarker(_ item: NSMenuItem, highlighted: Bool) -> NSImage? {
        let color: NSColor = highlighted ? .white : item.tag == activeAgentTag ? .systemBlue : .systemGray
        return NSImage(systemSymbolName: "pointer.arrow.motionlines", accessibilityDescription: item.image?.accessibilityDescription)?
            .withSymbolConfiguration(.init(paletteColors: [color]))
    }

    func menu(_ menu: NSMenu, willHighlight highlighted: NSMenuItem?) {
        for item in menu.items where item.tag == Self.activeAgentTag || item.tag == Self.inactiveAgentTag {
            item.image = Self.agentMarker(item, highlighted: item === highlighted)
        }
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
