import AppKit
import RemoraCore

@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var connectionsWindowController: ConnectionsWindowController?
    private let sessionWindows = SessionWindows()

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        do {
            connectionsWindowController = ConnectionsWindowController(
                connectionStore: try ConnectionStore(),
                credentialStore: CredentialStore(),
                sessionWindows: sessionWindows
            )
            showConnectionsWindow()
        } catch {
            NSApplication.shared.presentError(error)
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showConnectionsWindow()
        return true
    }

    @objc private func newConnection(_ sender: Any?) {
        showConnectionsWindow()
        connectionsWindowController?.newConnection(sender)
    }

    @objc private func showSettings(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Settings"
        alert.informativeText = "Remora has no settings yet."
        alert.runModal()
    }

    @objc private func showHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Remora Help"
        alert.informativeText = "Remora is a personal remote desktop client."
        alert.runModal()
    }

    @objc private func showConnectionsWindow(_ sender: Any?) {
        showConnectionsWindow()
    }

    private func showConnectionsWindow() {
        connectionsWindowController?.showWindow(nil)
        connectionsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    private func configureMenu() {
        let mainMenu = NSMenu()
        let appMenu = addMenu("Remora", to: mainMenu)
        appMenu.addItem(withTitle: "About Remora", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApplication.shared.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Remora", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Remora", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenu = addMenu("File", to: mainMenu)
        fileMenu.addItem(withTitle: "New Connection", action: #selector(newConnection(_:)), keyEquivalent: "n").target = self
        fileMenu.addItem(withTitle: "Connect", action: #selector(ConnectionsViewController.connect(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenu = addMenu("Edit", to: mainMenu)
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let delete = editMenu.addItem(
            withTitle: "Delete",
            action: #selector(ConnectionsViewController.delete(_:)),
            keyEquivalent: String(UnicodeScalar(NSBackspaceCharacter)!)
        )
        delete.keyEquivalentModifierMask = .command
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find…", action: #selector(ConnectionsWindowController.startSearch(_:)), keyEquivalent: "f")

        let viewMenu = addMenu("View", to: mainMenu)
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]

        let windowMenu = addMenu("Window", to: mainMenu)
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Connections", action: #selector(showConnectionsWindow(_:)), keyEquivalent: "0").target = self
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApplication.shared.windowsMenu = windowMenu

        let helpMenu = addMenu("Help", to: mainMenu)
        helpMenu.addItem(withTitle: "Remora Help", action: #selector(showHelp(_:)), keyEquivalent: "?").target = self
        NSApplication.shared.helpMenu = helpMenu
        NSApplication.shared.mainMenu = mainMenu
    }

    private func addMenu(_ title: String, to mainMenu: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        mainMenu.addItem(item)
        return menu
    }
}
