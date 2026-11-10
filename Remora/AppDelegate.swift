import AppKit
import RemoraCore
import SwiftUI
import os

@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private let settings = NSHostingSceneRepresentation { Settings { SettingsView() } }
    private var statusMenu: StatusMenu?
    private var sessionTabs: SessionTabs?
    private var commandLineController: CommandLineController?
    private var terminationPending = false
    private var commandLineQuit = false
    /// The command line launches Remora this way: no window and no Dock icon, only the menu bar icon.
    private static let launchedInBackground = CommandLine.arguments.contains("--cli-background")
    #if DEBUG
    private var rendererDemo: RendererDemo?
    private var shortcutCaptureDemo: ShortcutCaptureDemo?
    #endif

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(launchedInBackground ? .accessory : .regular)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.addSceneRepresentation(settings)
        do {
            #if DEBUG
            if CommandLine.arguments.contains("--shortcut-capture-demo") {
                configureMenu()
                shortcutCaptureDemo = ShortcutCaptureDemo(renderer: try FrameRenderer())
                return
            }
            #endif
            let connectionStore = try ConnectionStore()
            let credentialStore = CredentialStore()
            let sessionTabs = SessionTabs(connectionStore: connectionStore, credentialStore: credentialStore)
            self.sessionTabs = sessionTabs
            let windowController = MainWindowController(
                connectionStore: connectionStore,
                credentialStore: credentialStore,
                sessionTabs: sessionTabs
            )
            mainWindowController = windowController
            configureMenu()
            statusMenu = StatusMenu(
                sessionTabs: sessionTabs,
                windowController: windowController,
                onOpen: { [weak self] in self?.showMainWindow() },
                onShowTab: { [weak self] id in
                    self?.showMainWindow()
                    self?.mainWindowController?.select(id)
                },
                onShowSettings: { [weak self] in self?.showSettings(nil) }
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil
            )
            if let mainWindowController {
                let controller = CommandLineController(
                    mainWindow: mainWindowController, sessions: sessionTabs,
                    connectionStore: connectionStore, credentialStore: credentialStore,
                    show: { [weak self] page in
                        switch page {
                        case "settings": self?.showSettings(nil)
                        case "connections": self?.showConnections(nil)
                        default: self?.showMainWindow()
                        }
                    },
                    quit: { [weak self] in
                        self?.commandLineQuit = true
                        NSApplication.shared.terminate(nil)
                    })
                commandLineController = controller
                Task {
                    do { try await controller.start() } catch {
                        Logger(subsystem: "dev.sadiksaifi.Remora", category: "Control").error(
                            "Control listener failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            if !Self.launchedInBackground { showMainWindow() }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "RemoraRendererDemo") {
                rendererDemo = RendererDemo(renderer: try FrameRenderer())
                rendererDemo?.showWindow(nil)
            }
            #endif
        } catch {
            configureMenu()
            NSApplication.shared.presentError(error)
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let sessionTabs else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        guard commandLineQuit || confirmQuit() else { return .terminateCancel }
        terminationPending = true
        Task { @MainActor in
            await sessionTabs.prepareToQuit()
            await commandLineController?.stop()
            if terminationPending {
                terminationPending = false
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        // Writers have their own eight-second cancellation deadline. This is the app-level bound.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            if terminationPending {
                let log = Logger(subsystem: "dev.sadiksaifi.Remora", category: "Capture")
                for url in sessionTabs.unfinishedCaptureURLs {
                    log.error(
                        "Quit timed out finishing \(url.path, privacy: .public). The reserved file and a hidden .Remora-*.partial.mov may remain in its folder."
                    )
                }
                terminationPending = false
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    /// Asks before quitting ends live sessions. Returns true to quit.
    private func confirmQuit() -> Bool {
        guard let sessionTabs else { return true }
        let live = sessionTabs.liveCount
        guard live > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = "Quit Remora and disconnect \(live) \(live == 1 ? "session" : "sessions")?"
        if sessionTabs.isRecording { alert.informativeText = "Recordings in progress are saved." }
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        // Quit Remora in the menu bar menu can run with no window open.
        NSApplication.shared.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    func applicationWillTerminate(_ notification: Notification) {
        #if DEBUG
        rendererDemo?.stop()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    @objc private func newConnection(_ sender: Any?) {
        showMainWindow()
        mainWindowController?.newConnection(sender)
    }

    @objc private func showSettings(_ sender: Any?) {
        // SwiftUI may show the window later, so the Dock icon can't wait to find it.
        NSApplication.shared.setActivationPolicy(.regular)
        settings.environment.openSettings()
        NSApplication.shared.activate()
    }

    @objc private func showHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Remora Help"
        alert.informativeText = """
            Double-click a connection to open it in a tab. Each connection has at most one tab.

            In a session, Command acts as the Windows or Super key, Control as Control, and Option as Alt.

            These shortcuts stay on this Mac while a session has the keyboard:
            Control-Option-Command-[ and ] show the previous and next tab.
            Control-Option-Command-1 through 9 show tab 1 through 9.
            Control-Option-Command-H shows the connections list.
            Control-Option-Command-W closes the tab and disconnects it.
            Control-Option-Command-S saves a screenshot of the remote desktop. Add Shift to copy it instead.
            Control-Option-Command-R starts or stops recording the remote desktop.
            Control-Option-Command-Escape releases the keyboard. Click the remote desktop to capture it again.
            Control-Command-F enters or exits full screen. Command-Q quits Remora.
            """
        alert.runModal()
    }

    /// Shows the window with the connections list.
    @objc private func showConnections(_ sender: Any?) {
        showMainWindow()
        mainWindowController?.showHome(sender)
    }

    private func showMainWindow() {
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        updateActivationPolicy()
        NSApplication.shared.activate()
    }

    /// The Dock icon shows while the main window or Settings is open, including minimized.
    private func updateActivationPolicy() {
        let windowOpen = [mainWindowController?.window, NSApplication.shared.settingsWindow].contains {
            guard let window = $0 else { return false }
            return window.isVisible || window.isMiniaturized
        }
        NSApplication.shared.setActivationPolicy(windowOpen ? .regular : .accessory)
    }

    /// A closing window is still visible here, so the policy updates once it has closed.
    @objc private func windowWillClose(_ notification: Notification) {
        Task { @MainActor in updateActivationPolicy() }
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
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Connect", action: #selector(ConnectionsViewController.connect(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Edit Connection…", action: #selector(ConnectionsViewController.editConnection(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Duplicate", action: #selector(ConnectionsViewController.duplicateConnection(_:)), keyEquivalent: "d")
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
        editMenu.addItem(withTitle: "Find…", action: #selector(MainWindowController.startSearch(_:)), keyEquivalent: "f")

        let viewMenu = addMenu("View", to: mainMenu)
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]

        // While a connected desktop has the keyboard, only Cmd-Q, Ctrl-Cmd-F, and the
        // Ctrl-Option-Cmd shortcuts stay local. Other shortcuts here act once it is released.
        let localChord: NSEvent.ModifierFlags = [.control, .option, .command]
        let sessionMenu = addMenu("Session", to: mainMenu)
        sessionMenu.addItem(withTitle: "Disconnect", action: #selector(MainWindowController.disconnectSession(_:)), keyEquivalent: "")
        sessionMenu.addItem(withTitle: "Reconnect", action: #selector(MainWindowController.reconnectSession(_:)), keyEquivalent: "r")
        sessionMenu.addItem(.separator())
        sessionMenu.addItem(withTitle: "Send Ctrl-Alt-Delete", action: #selector(MainWindowController.sendCtrlAltDelete(_:)), keyEquivalent: "")
        sessionMenu.addItem(.separator())
        for item in MainWindowController.makeCaptureItems() { sessionMenu.addItem(item) }
        sessionMenu.addItem(.separator())
        sessionMenu.addItem(withTitle: "Take Over", action: #selector(MainWindowController.toggleAgentControl(_:)), keyEquivalent: "")
        sessionMenu.addItem(withTitle: "Stop Agent Control", action: #selector(MainWindowController.stopAgentControl(_:)), keyEquivalent: "")
        sessionMenu.addItem(withTitle: "Stop All Agent Control", action: #selector(MainWindowController.stopAllAgentControl(_:)), keyEquivalent: "")
        sessionMenu.addItem(.separator())
        sessionMenu.addItem(
            withTitle: "Release Keyboard Capture",
            action: #selector(MainWindowController.releaseKeyboardCapture(_:)),
            keyEquivalent: "\u{1b}"
        ).keyEquivalentModifierMask = localChord
        sessionMenu.addItem(.separator())
        sessionMenu.addItem(withTitle: "Close Tab", action: #selector(MainWindowController.closeTab(_:)), keyEquivalent: "w")
            .keyEquivalentModifierMask = localChord

        let windowMenu = addMenu("Window", to: mainMenu)
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let connections = windowMenu.addItem(withTitle: "Connections", action: #selector(showConnections(_:)), keyEquivalent: "h")
        connections.keyEquivalentModifierMask = localChord
        connections.target = self
        windowMenu.addItem(withTitle: "Show Previous Tab", action: #selector(MainWindowController.showPreviousTab(_:)), keyEquivalent: "[")
            .keyEquivalentModifierMask = localChord
        windowMenu.addItem(withTitle: "Show Next Tab", action: #selector(MainWindowController.showNextTab(_:)), keyEquivalent: "]")
            .keyEquivalentModifierMask = localChord
        for item in mainWindowController?.tabMenuItems ?? [] { windowMenu.addItem(item) }
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
