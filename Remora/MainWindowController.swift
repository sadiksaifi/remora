import AppKit
import RemoraCore
import SwiftUI

/// The app's only window. It shows the connections list or one session, and each session is a tab in the toolbar.
/// Native window tabbing is off, so window managers see exactly one window.
/// The toolbar leads with the tabs and the button that shows the connections list. Its trailing end holds the
/// shown page's controls: search on the connections list, agent control and capture on a session, then More.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate,
    NSMenuItemValidation, NSMenuDelegate
{
    private static let tabsItem = NSToolbarItem.Identifier("tabs")
    private static let connectionsItem = NSToolbarItem.Identifier("connections")
    private static let agentItem = NSToolbarItem.Identifier("agent")
    private static let captureItem = NSToolbarItem.Identifier("capture")
    private static let searchItem = NSToolbarItem.Identifier("search")
    private static let moreItem = NSToolbarItem.Identifier("more")
    /// Below this window width the capture group leaves the toolbar and the agent button keeps only its icon.
    /// The capture commands stay in the More menu.
    private static let compactWidth: CGFloat = 640
    /// Whether the toolbar last showed its compact set of controls.
    private var shownCompact = false
    /// Narrower than the search field's minimum, so the toolbar shows the collapsed search button.
    private static let collapsedSearchWidth: CGFloat = 30
    private static let expandedSearchWidth: CGFloat = 240
    /// A filter that is not being edited keeps this width in a compact toolbar, beside the tabs.
    private static let compactFilterWidth: CGFloat = 96

    private let sessionTabs: SessionTabs
    private let connectionsViewController: ConnectionsViewController
    /// Holds the shown page: the connections list or one session tab.
    private let pageViewController = NSViewController()
    private var currentPage: NSViewController
    private let tabsToolbarItem = NSToolbarItem(itemIdentifier: MainWindowController.tabsItem)
    private let tabStrip: NSHostingView<SessionTabStrip>
    private let tabStripLayout = SessionTabStripLayout()
    private let tabStripWidth: NSLayoutConstraint
    private let connectionsToolbarItem = NSToolbarItem(itemIdentifier: MainWindowController.connectionsItem)
    private let connectionsButton = NSButton()
    private let agentToolbarItem = NSToolbarItem(itemIdentifier: MainWindowController.agentItem)
    private let agentButton = NSHostingView(rootView: AgentControlButton())
    private let captureToolbarItem = NSToolbarItem(itemIdentifier: MainWindowController.captureItem)
    /// Capture Keyboard, Take Screenshot, and Start or Stop Recording, in that order.
    private let captureControl = NSSegmentedControl()
    private let searchToolbarItem = NSSearchToolbarItem(itemIdentifier: MainWindowController.searchItem)
    private let searchWidth: NSLayoutConstraint
    private let moreToolbarItem = NSMenuToolbarItem(itemIdentifier: MainWindowController.moreItem)
    private var callout: NSPopover?
    /// The control state the toolbar last showed, which tells an agent's change from a change of tab.
    private var shownControl: (tab: UUID, state: SessionControl.State, agent: String)?
    private var shownCapture: CaptureControls?
    /// Window > a separator and tab 1 through 9, hidden past the last tab.
    private(set) var tabMenuItems: [NSMenuItem] = []
    private var eventMonitor: Any?

    init(connectionStore: ConnectionStore, credentialStore: CredentialStore, sessionTabs: SessionTabs) {
        self.sessionTabs = sessionTabs
        connectionsViewController = ConnectionsViewController(
            connectionStore: connectionStore,
            credentialStore: credentialStore,
            sessionTabs: sessionTabs
        )
        currentPage = connectionsViewController
        tabStrip = NSHostingView(rootView: SessionTabStrip(tabs: sessionTabs, layout: tabStripLayout))
        tabStripWidth = tabStrip.widthAnchor.constraint(
            lessThanOrEqualToConstant: SessionTabStrip.idealTabWidth
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
        window.isReleasedWhenClosed = false
        // Sessions are tabs inside this one window. Native tabs are separate windows, so window
        // managers such as AeroSpace, yabai and Rectangle would see one window per session.
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
        // 480 x 320 with the 52 pt toolbar. The toolbar adds its height to a frame minimum when it attaches.
        window.contentMinSize = NSSize(width: 480, height: 268)
        // Place the window only once the toolbar has its height. A frame restored earlier grows
        // when the toolbar attaches, and Zoom then treats the pre-toolbar frame as the user's size.
        window.center()
        window.setFrameAutosaveName("Connections")
        window.initialFirstResponder = connectionsViewController.initialFirstResponder

        tabMenuItems =
            [.separator()]
            + (1...9).map { number in
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
        // A hand-over in progress is not part of a tab's state, so the agent button follows the session itself.
        NotificationCenter.default.addObserver(
            self, selector: #selector(controlDidChange(_:)), name: SessionViewController.controlDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowOcclusionDidChange(_:)), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        observeTabs()
        observeRecording()
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
        // An open More menu was built for the page that is leaving.
        moreToolbarItem.menu.cancelTrackingWithoutAnimation()
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

    /// The record button follows the shown session's recording, which also starts and stops from the command line.
    private func observeRecording() {
        withObservationTracking {
            _ = sessionTabs.selectedSession?.capture.recordingState
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateCaptureControls()
                self?.observeRecording()
            }
        }
    }

    private var isCompact: Bool {
        guard let window else { return false }
        return window.frame.width < Self.compactWidth
    }

    /// Shows the controls of the shown page. The tab strip and the Connections button show only while tabs are
    /// open, and without tabs the window title takes their place. The window title always names the shown page
    /// for the Window menu and accessibility.
    private func updateChrome() {
        guard let window else { return }
        let tabs = sessionTabs.tabs
        let session = sessionTabs.selectedSession
        shownCompact = isCompact
        searchWidth.constant = searchFieldWidth
        // A compact toolbar has no room for the tabs or the title beside the search field while it has the keyboard.
        let searchTakesToolbar = isCompact && session == nil && searchWidth.constant == Self.expandedSearchWidth
        tabsToolbarItem.isHidden = tabs.isEmpty || searchTakesToolbar
        connectionsToolbarItem.isHidden = tabs.isEmpty || searchTakesToolbar
        // A lone shown tab is its pill alone, without the track.
        tabStrip.rootView.showsTrack = tabs.count != 1 || session == nil
        connectionsButton.state = session == nil ? .on : .off
        searchToolbarItem.isHidden = session != nil
        captureToolbarItem.isHidden = session == nil || isCompact
        updateAgentControl()
        reportToolbarReveal()
        window.titleVisibility = tabs.isEmpty && !searchTakesToolbar ? .visible : .hidden
        let shown = tabs.first { $0.id == sessionTabs.selection }
        window.title = shown.map { tab in tab.display.map { "\(tab.title) – \($0)" } ?? tab.title } ?? "Connections"
        // In a compact toolbar the tabs beside the shown one keep only their icon.
        let restingAsIcons = isCompact && session != nil
        tabStrip.rootView.isCompact = restingAsIcons
        tabStripWidth.constant = SessionTabStrip.idealWidth(forTabCount: tabs.count, restingAsIcons: restingAsIcons)
        for item in tabMenuItems {
            if item.isSeparatorItem {
                item.isHidden = tabs.isEmpty
            } else {
                item.isHidden = !tabs.indices.contains(item.tag)
                if tabs.indices.contains(item.tag) { item.title = tabs[item.tag].title }
            }
        }
        updateCaptureControls()
    }

    // MARK: Full screen toolbar

    /// Full screen moves the toolbar into a window of its own, which is on screen only while the pointer
    /// at the top edge reveals it.
    @objc private func windowOcclusionDidChange(_ notification: Notification) {
        guard let toolbarWindow = tabStrip.window, toolbarWindow !== window, notification.object as? NSWindow === toolbarWindow else { return }
        reportToolbarReveal()
    }

    /// Tells the shown session whether the revealed toolbar covers the top of the remote screen.
    private func reportToolbarReveal() {
        let toolbarWindow = tabStrip.window
        sessionTabs.selectedSession?.toolbarRevealed(toolbarWindow !== window && toolbarWindow?.occlusionState.contains(.visible) == true)
    }

    // MARK: Agent control

    @objc private func controlDidChange(_ notification: Notification) {
        guard let session = notification.object as? SessionViewController, session === sessionTabs.selectedSession else { return }
        updateAgentControl()
    }

    /// The agent button exists only once a program has controlled the shown session.
    /// A change on the shown tab, as opposed to a change of tab, shows the callout that explains it.
    private func updateAgentControl() {
        let session = sessionTabs.selectedSession
        let control = session?.control
        let state = control?.state ?? .idle
        agentToolbarItem.isHidden = state == .idle
        agentButton.rootView = AgentControlButton(
            state: state,
            isTransferring: control?.isTransferring == true,
            agent: session?.agentName ?? "",
            isEnabled: control?.canTakeOver == true || (control?.canResume == true && session?.isConnected == true),
            showsTitle: !isCompact,
            action: { [weak session] in session?.toggleAgentControl() }
        )
        let previous = shownControl
        shownControl = session.map { ($0.connection.id, state, $0.agentName) }
        guard let session, let previous, previous.tab == session.connection.id else { return closeCallout() }
        guard previous.state != state || (state == .active && previous.agent != session.agentName) else { return }
        switch (previous.state, state) {
        // A second program that takes the input is news as well.
        case (.idle, .active), (.active, .active): showCallout(.inControl, agent: session.agentName)
        case (.active, .stopped), (.paused, .stopped): showCallout(.stopped, agent: session.agentName)
        default: closeCallout()
        }
    }

    /// A stock popover under the agent button, closed again after four seconds. Full screen hides the toolbar
    /// and shows the same news in a capsule over the remote screen instead.
    private func showCallout(_ kind: AgentControlCallout.Kind, agent: String) {
        closeCallout()
        guard let window, window.isVisible, !window.styleMask.contains(.fullScreen) else { return }
        // The button may have joined the toolbar in this pass.
        window.layoutIfNeeded()
        guard agentButton.window === window else { return }
        let content = NSHostingController(rootView: AgentControlCallout(kind: kind, agent: agent))
        content.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.contentViewController = content
        popover.show(relativeTo: agentButton.bounds, of: agentButton, preferredEdge: .maxY)
        callout = popover
        Task { @MainActor [weak self, weak popover] in
            try? await Task.sleep(for: SessionNotices.duration)
            guard let self, let popover, callout === popover else { return }
            closeCallout()
        }
    }

    private func closeCallout() {
        callout?.close()
        callout = nil
    }

    // MARK: Actions

    @objc func newConnection(_ sender: Any?) {
        connectionsViewController.newConnection(sender)
    }

    /// Search belongs to the connections list, so Find shows the list first.
    @objc func startSearch(_ sender: Any?) {
        select(nil)
        guard currentPage === connectionsViewController else { return }
        // A session hides the search item. The toolbar puts the field back in the window in its next layout.
        window?.layoutIfNeeded()
        searchToolbarItem.beginSearchInteraction()
        updateSearchWidth()
    }

    @objc func showHome(_ sender: Any?) {
        select(nil)
        // The button toggled itself on the click. It shows the page, not the click.
        connectionsButton.state = sessionTabs.selection == nil ? .on : .off
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
        guard let id = (sender as? NSMenuItem)?.representedObject as? UUID ?? sessionTabs.selection else { return }
        close(id)
    }

    /// Take Over, which validation retitles Resume while the tab is paused or stopped.
    @objc func toggleAgentControl(_ sender: Any?) { targetSession(sender)?.toggleAgentControl() }
    @objc func stopAgentControl(_ sender: Any?) {
        guard let session = targetSession(sender) else { return }
        Task { do { try await session.handoverAgentControl(.stop) } catch { NSApp.presentError(error) } }
    }
    @objc func stopAllAgentControl(_ sender: Any?) {
        let targets = sessionTabs.tabs.compactMap { sessionTabs.session(for: $0.id) }
        Task {
            for session in targets {
                do { try await session.handoverAgentControl(.stop) } catch { NSApp.presentError(error) }
            }
        }
    }

    @objc func disconnectSession(_ sender: Any?) { targetSession(sender)?.disconnectSession() }
    @objc func reconnectSession(_ sender: Any?) { sessionTabs.selectedSession?.reconnect() }
    @objc func sendCtrlAltDelete(_ sender: Any?) { sessionTabs.selectedSession?.sendCtrlAltDelete() }
    @objc func releaseKeyboardCapture(_ sender: Any?) { sessionTabs.selectedSession?.releaseKeyboardCapture() }
    @objc func takeScreenshot(_ sender: Any?) { targetSession(sender)?.captureScreenshot(copyToClipboard: false) }
    @objc func copyScreenshot(_ sender: Any?) { targetSession(sender)?.captureScreenshot(copyToClipboard: true) }
    @objc func toggleRecording(_ sender: Any?) { targetSession(sender)?.toggleRecording() }
    /// A tab's menu stops a recording and never starts one. A recording that has ended ignores the request.
    @objc private func stopRecording(_ sender: Any?) {
        guard let session = targetSession(sender) else { return }
        Task { await session.stopRecording() }
    }
    @objc func showNextDisplay(_ sender: Any?) { sessionTabs.selectedSession?.selectAdjacentDisplay(forward: true) }
    @objc func showPreviousDisplay(_ sender: Any?) { sessionTabs.selectedSession?.selectAdjacentDisplay(forward: false) }

    /// True while the shown session's desktop receives the keys. The session reports each change, which
    /// covers a window that is no longer the key window and an agent that holds the input.
    private var hasKeyboard: Bool {
        sessionTabs.tabs.first { $0.id == sessionTabs.selection }?.isKeyboardCaptured == true
    }

    /// Gives the shown session's desktop the keyboard, or takes it back.
    @objc func toggleKeyboardCapture(_ sender: Any?) {
        guard let session = sessionTabs.selectedSession else { return }
        if hasKeyboard { session.releaseKeyboardCapture() } else { session.focusDesktop() }
    }

    /// A global setting, so every session shows the same state.
    @objc func toggleShowKeyPresses(_ sender: Any?) {
        UserDefaults.standard.set(!AppSettings.showKeyPresses, forKey: AppSettings.showKeyPressesKey)
    }

    @objc private func chooseDisplay(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? UInt32, let session = sessionTabs.selectedSession else { return }
        let displays = session.displays
        guard displays.pendingID != nil || displays.selectedID != display else { return }
        if case .failure = session.selectDisplay(display) { NSSound.beep() }
    }

    /// The Display section of the More menu, or nothing while the remote reports at most one display.
    private func displayItems(for session: SessionViewController) -> [NSMenuItem] {
        let displays = session.displays
        guard displays.displays.count > 1 else { return [] }
        let shown = displays.pendingID ?? displays.selectedID
        return [.sectionHeader(title: "Display")]
            + displays.ordered.map { display in
                let item = NSMenuItem(title: displays.name(of: display.id) ?? "", action: #selector(chooseDisplay(_:)), keyEquivalent: "")
                item.subtitle = "\(display.size.width) × \(display.size.height)" + (display.isMain ? " · Main" : "")
                item.target = self
                item.representedObject = display.id
                item.state = display.id == shown ? .on : .off
                return item
            }
    }

    /// Capture Keyboard and Show Key Presses, for the Session menu and the More menu. Validation sets their checkmarks.
    static func makeKeyboardItems() -> [NSMenuItem] {
        [
            NSMenuItem(title: "Capture Keyboard", action: #selector(toggleKeyboardCapture(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Show Key Presses", action: #selector(toggleShowKeyPresses(_:)), keyEquivalent: ""),
        ]
    }

    /// Take Screenshot, Copy Screenshot, and Start Recording, for the Session menu and the More menu.
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

    var canStopAnyAgent: Bool {
        sessionTabs.tabs.contains { sessionTabs.session(for: $0.id)?.control.canStop == true }
    }

    /// Take Over or Resume and Stop Agent Control for one tab, leaving out the items that don't apply.
    /// For the tab's menu and the menu bar item's menu.
    func agentControlItems(for id: UUID) -> [NSMenuItem] {
        guard let control = sessionTabs.session(for: id)?.control else { return [] }
        var items: [NSMenuItem] = []
        func add(_ title: String, _ action: Selector, _ applies: Bool) {
            guard applies else { return }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = id
            items.append(item)
        }
        add(
            control.canResume ? "Resume" : "Take Over", #selector(toggleAgentControl(_:)),
            control.canTakeOver || (control.canResume && sessionTabs.session(for: id)?.isConnected == true))
        add("Stop Agent Control", #selector(stopAgentControl(_:)), control.canStop)
        return items
    }

    /// An item from a tab's own menu names its tab. Other items act on the shown tab.
    private func targetSession(_ sender: Any?) -> SessionViewController? {
        if let id = (sender as? NSMenuItem)?.representedObject as? UUID { return sessionTabs.session(for: id) }
        return sessionTabs.selectedSession
    }

    // MARK: Validation

    private enum RecordingCommand { case start, stop, finishing }

    private func recordingCommand(for session: SessionViewController?) -> RecordingCommand {
        switch session?.capture.recordingState {
        case .recording: .stop
        case .finishing: .finishing
        default: .start
        }
    }

    private func canCapture(_ session: SessionViewController?) -> Bool {
        session?.isConnected == true && session?.displayIsReady == true
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let session = targetSession(menuItem)
        switch menuItem.action {
        case #selector(showHome(_:)):
            return canChangeTabs
        case #selector(startSearch(_:)):
            return currentPage === connectionsViewController || canChangeTabs
        case #selector(showPreviousTab(_:)), #selector(showNextTab(_:)):
            return !sessionTabs.tabs.isEmpty && canChangeTabs
        case #selector(showTab(_:)):
            let tabs = sessionTabs.tabs
            menuItem.state =
                tabs.indices.contains(menuItem.tag) && tabs[menuItem.tag].id == sessionTabs.selection
                ? .on : .off
            return tabs.indices.contains(menuItem.tag) && canChangeTabs
        case #selector(closeTab(_:)):
            return session != nil && canChangeTabs
        case #selector(toggleKeyboardCapture(_:)):
            menuItem.state = hasKeyboard ? .on : .off
            return session?.isConnected == true
        case #selector(chooseDisplay(_:)), #selector(showNextDisplay(_:)), #selector(showPreviousDisplay(_:)):
            return sessionTabs.selectedSession?.canChooseDisplay == true
        case #selector(toggleShowKeyPresses(_:)):
            menuItem.state = AppSettings.showKeyPresses ? .on : .off
            return true
        case #selector(toggleAgentControl(_:)):
            let resumable = session?.control.canResume == true
            menuItem.title = resumable ? "Resume" : "Take Over"
            return resumable ? session?.isConnected == true : session?.control.canTakeOver == true
        case #selector(stopAgentControl(_:)): return session?.control.canStop == true
        case #selector(stopAllAgentControl(_:)): return canStopAnyAgent
        case #selector(disconnectSession(_:)):
            return session?.canDisconnect ?? false
        case #selector(reconnectSession(_:)):
            return session?.canReconnect ?? false
        case #selector(sendCtrlAltDelete(_:)):
            return session?.isConnected == true && session?.control.allowsHumanInput == true
        case #selector(releaseKeyboardCapture(_:)):
            return hasKeyboard
        case #selector(takeScreenshot(_:)), #selector(copyScreenshot(_:)):
            return canCapture(session)
        case #selector(stopRecording(_:)):
            return recordingCommand(for: session) == .stop
        case #selector(toggleRecording(_:)):
            switch recordingCommand(for: session) {
            case .stop:
                menuItem.title = "Stop Recording"
                return true
            case .finishing:
                menuItem.title = "Finishing Recording\u{2026}"
                return false
            case .start:
                menuItem.title = "Start Recording"
                return canCapture(session)
            }
        default:
            return true
        }
    }

    private struct CaptureControls: Equatable {
        var hasKeyboard: Bool
        var isConnected: Bool
        var canCapture: Bool
        var recording: RecordingCommand
    }

    /// The capture group follows the same rules as the menu items with the same actions. A click selects its
    /// segment, so `afterClick` puts back what the session says: only Capture Keyboard stays selected, while
    /// the desktop has the keyboard. Otherwise the control changes only when the session does.
    private func updateCaptureControls(afterClick: Bool = false) {
        let session = sessionTabs.selectedSession
        let controls = CaptureControls(
            hasKeyboard: hasKeyboard, isConnected: session?.isConnected == true, canCapture: canCapture(session),
            recording: recordingCommand(for: session))
        guard afterClick || controls != shownCapture else { return }
        captureControl.setSelected(controls.hasKeyboard, forSegment: 0)
        captureControl.setSelected(false, forSegment: 1)
        captureControl.setSelected(false, forSegment: 2)
        captureControl.setEnabled(controls.isConnected, forSegment: 0)
        captureControl.setEnabled(controls.canCapture, forSegment: 1)
        let command = controls.recording
        if command != shownCapture?.recording {
            let title =
                switch command {
                case .start: "Start Recording"
                case .stop: "Stop Recording"
                case .finishing: "Finishing Recording"
                }
            captureControl.setToolTip(title, forSegment: 2)
            captureControl.setImage(
                command == .stop
                    ? NSImage(systemSymbolName: "stop.circle", accessibilityDescription: title)?
                        .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
                    : NSImage(systemSymbolName: "record.circle", accessibilityDescription: title),
                forSegment: 2)
        }
        captureControl.setEnabled(command == .stop || (command == .start && controls.canCapture), forSegment: 2)
        shownCapture = controls
    }

    /// The clicked segment is the one whose selection no longer matches the session.
    @objc private func captureControlClicked(_ sender: NSSegmentedControl) {
        let session = sessionTabs.selectedSession
        if sender.isSelected(forSegment: 1) {
            session?.captureScreenshot(copyToClipboard: false)
        } else if sender.isSelected(forSegment: 2) {
            session?.toggleRecording()
        } else if sender.isSelected(forSegment: 0) != hasKeyboard {
            toggleKeyboardCapture(sender)
        }
        updateCaptureControls(afterClick: true)
    }

    // MARK: Menus

    /// The More menu is built each time it opens, for the shown page. New Connection always leads it.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // The toolbar takes the first item of this menu for the button's title and leaves it out of the open menu.
        defer { menu.insertItem(NSMenuItem(), at: 0) }
        menu.addItem(withTitle: "New Connection…", action: #selector(newConnection(_:)), keyEquivalent: "n").target = self
        guard let session = sessionTabs.selectedSession else {
            let connections = [
                NSMenuItem(title: "Connect", action: #selector(ConnectionsViewController.connect(_:)), keyEquivalent: "o"),
                NSMenuItem(title: "Edit Connection…", action: #selector(ConnectionsViewController.editConnection(_:)), keyEquivalent: ""),
                NSMenuItem(title: "Duplicate", action: #selector(ConnectionsViewController.duplicateConnection(_:)), keyEquivalent: "d"),
                NSMenuItem(
                    title: "Delete", action: #selector(ConnectionsViewController.delete(_:)),
                    keyEquivalent: String(UnicodeScalar(NSBackspaceCharacter)!)),
            ]
            for item in connections { item.target = connectionsViewController }
            add([connections], to: menu)
            return
        }
        let close = NSMenuItem(title: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "w")
        close.keyEquivalentModifierMask = [.control, .option, .command]
        var ending = [close]
        if session.canDisconnect {
            ending.insert(NSMenuItem(title: "Disconnect", action: #selector(disconnectSession(_:)), keyEquivalent: ""), at: 0)
        }
        if session.control.canStop {
            ending.insert(NSMenuItem(title: "Stop Agent Control", action: #selector(stopAgentControl(_:)), keyEquivalent: ""), at: 0)
        }
        let groups = [
            displayItems(for: session),
            Self.makeKeyboardItems(),
            Self.makeCaptureItems(),
            [NSMenuItem(title: "Send Ctrl-Alt-Delete", action: #selector(sendCtrlAltDelete(_:)), keyEquivalent: "")],
            ending,
        ]
        for item in groups.joined() { item.target = self }
        add(groups, to: menu)
    }

    /// Adds each group that has items after a separator.
    private func add(_ groups: [[NSMenuItem]], to menu: NSMenu) {
        for group in groups where !group.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for item in group { menu.addItem(item) }
        }
    }

    /// The toolbar takes secondary clicks for its own menu before the strip's views see them.
    private func showTabMenu(for event: NSEvent) -> Bool {
        guard event.window != nil, event.window === tabStrip.window, !tabStrip.isHiddenOrHasHiddenAncestor else {
            return false
        }
        let point = tabStrip.convert(event.locationInWindow, from: nil)
        guard tabStrip.bounds.contains(point), let id = tabStripLayout.tab(at: point) else { return false }
        NSMenu.popUpContextMenu(tabMenu(for: id), with: event, for: tabStrip)
        return true
    }

    /// Opens a tab's menu under the tab, for VoiceOver. The menu opens on the next turn of the main loop,
    /// because `popUp` returns only when the menu closes and the accessibility action must return before that.
    /// A run loop block carries it: a main-actor task would hold up every other task until the menu closes.
    private func showTabMenu(forTab id: UUID) {
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let frame = self.tabStripLayout.frame(of: id) else { return }
                self.tabMenu(for: id).popUp(positioning: nil, at: NSPoint(x: frame.minX, y: frame.maxY), in: self.tabStrip)
            }
        }
    }

    /// A tab's menu holds what a tab that is not showing may need: the agent control items, Stop Recording and
    /// Disconnect where they apply, and Close Tab. Everything else is in the shown session's More menu.
    private func tabMenu(for id: UUID) -> NSMenu {
        let menu = NSMenu()
        let session = sessionTabs.session(for: id)
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = id
            return item
        }
        var recording: [NSMenuItem] = []
        if recordingCommand(for: session) == .stop { recording = [item("Stop Recording", #selector(stopRecording(_:)))] }
        add(
            [
                agentControlItems(for: id),
                recording,
                session?.canDisconnect == true ? [item("Disconnect", #selector(disconnectSession(_:)))] : [],
                [item("Close Tab", #selector(closeTab(_:)))],
            ], to: menu)
        return menu
    }

    // MARK: Search

    @objc private func searchChanged(_ sender: NSSearchField) {
        updateSearchWidth()
        connectionsViewController.searchText = sender.stringValue
    }

    /// The field is a button until it has the keyboard or a filter. In a compact toolbar a filter that is
    /// not being edited keeps a short field, so the tabs fit beside it.
    private var searchFieldWidth: CGFloat {
        let field = searchToolbarItem.searchField
        if field.currentEditor() != nil { return Self.expandedSearchWidth }
        if field.stringValue.isEmpty { return Self.collapsedSearchWidth }
        return isCompact ? Self.compactFilterWidth : Self.expandedSearchWidth
    }

    private func updateSearchWidth() {
        if searchFieldWidth != searchWidth.constant { updateChrome() }
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

    /// Escape in the empty search field closes it. With text in it, the field clears the text first.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)), control.stringValue.isEmpty else { return false }
        window?.makeFirstResponder(connectionsViewController.initialFirstResponder)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // Collapse once the field has given up the keyboard, unless a filter is active.
        Task { @MainActor [weak self] in
            guard let self, searchToolbarItem.searchField.currentEditor() == nil else { return }
            updateSearchWidth()
            if searchToolbarItem.searchField.stringValue.isEmpty { searchToolbarItem.endSearchInteraction() }
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

    func windowWillEnterFullScreen(_ notification: Notification) {
        closeCallout()
        sessionTabs.selectedSession?.windowWillTransition()
    }
    func windowWillExitFullScreen(_ notification: Notification) { sessionTabs.selectedSession?.windowWillTransition() }
    func windowDidEnterFullScreen(_ notification: Notification) {
        sessionTabs.selectedSession?.windowDidTransition()
        reportToolbarReveal()
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        sessionTabs.selectedSession?.windowDidTransition()
        reportToolbarReveal()
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { sessionTabs.selectedSession?.windowDidTransition() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { sessionTabs.selectedSession?.windowDidTransition() }
    func windowDidEndLiveResize(_ notification: Notification) { sessionTabs.selectedSession?.windowDidChangeSize() }
    func windowDidChangeScreen(_ notification: Notification) { sessionTabs.selectedSession?.windowDidChangeSize() }

    /// AppKit sends this after every event. The search field takes the keyboard and the remote display
    /// changes without a notification of their own, so both are compared here with what the toolbar shows.
    func windowDidUpdate(_ notification: Notification) {
        updateSearchWidth()
        updateCaptureControls()
    }

    /// Crossing `compactWidth` changes which controls the toolbar holds.
    func windowDidResize(_ notification: Notification) {
        if isCompact != shownCompact { updateChrome() }
    }

    // MARK: Toolbar

    private func configureToolbarItems() {
        tabStrip.rootView = SessionTabStrip(
            tabs: sessionTabs,
            layout: tabStripLayout,
            onSelect: { [weak self] id in self?.select(id) },
            onClose: { [weak self] id in self?.close(id) },
            onStopRecording: { [weak self] id in
                guard let session = self?.sessionTabs.session(for: id) else { return }
                Task { await session.stopRecording() }
            },
            onShowMenu: { [weak self] id in self?.showTabMenu(forTab: id) }
        )
        tabStrip.sizingOptions = []
        tabStrip.safeAreaRegions = []
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        // The strip grows to its ideal width, then shrinks to fit the toolbar.
        NSLayoutConstraint.activate([
            tabStrip.heightAnchor.constraint(equalToConstant: SessionTabStrip.height),
            tabStrip.widthAnchor.constraint(greaterThanOrEqualToConstant: SessionTabStrip.minimumWidth),
            tabStripWidth,
        ])
        tabsToolbarItem.view = tabStrip
        // The strip draws its own track. The toolbar's glass belongs to the shown tab alone.
        tabsToolbarItem.isBordered = false
        tabsToolbarItem.label = "Tabs"
        tabsToolbarItem.visibilityPriority = .high

        // A button and not an image item, so it can draw pressed while the connections list shows
        // and carry an accessibility identifier.
        connectionsButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Show Connections")
        connectionsButton.bezelStyle = .toolbar
        connectionsButton.setButtonType(.pushOnPushOff)
        connectionsButton.target = self
        connectionsButton.action = #selector(showHome(_:))
        connectionsButton.setAccessibilityIdentifier("showConnections")
        connectionsToolbarItem.view = connectionsButton
        connectionsButton.setAccessibilityLabel("Show Connections")
        connectionsToolbarItem.label = "Show Connections"
        connectionsToolbarItem.toolTip = "Show Connections"
        connectionsToolbarItem.visibilityPriority = .high

        agentButton.sizingOptions = .intrinsicContentSize
        agentToolbarItem.view = agentButton
        agentToolbarItem.label = "Agent Control"
        agentToolbarItem.visibilityPriority = .high

        captureControl.segmentCount = 3
        captureControl.trackingMode = .selectAny
        for (segment, (symbol, title)) in [("keyboard", "Capture Keyboard"), ("camera", "Take Screenshot")].enumerated() {
            captureControl.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: title), forSegment: segment)
            captureControl.setToolTip(title, forSegment: segment)
        }
        for segment in 0..<3 { captureControl.setWidth(38, forSegment: segment) }
        captureControl.target = self
        captureControl.action = #selector(captureControlClicked(_:))
        captureControl.setAccessibilityIdentifier("captureControls")
        captureToolbarItem.view = captureControl
        captureToolbarItem.label = "Capture"

        let field = searchToolbarItem.searchField
        field.setAccessibilityIdentifier("connectionsSearch")
        field.placeholderString = "Search"
        field.target = self
        field.action = #selector(searchChanged(_:))
        field.delegate = self
        // The item keeps an open field at least this wide for as long as the search lasts, so it is the short
        // width. `searchWidth` widens the field past it.
        searchToolbarItem.preferredWidthForSearchField = Self.compactFilterWidth
        searchWidth.priority = .init(500)
        searchWidth.isActive = true

        moreToolbarItem.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")
        moreToolbarItem.label = "More"
        moreToolbarItem.toolTip = "More"
        moreToolbarItem.showsIndicator = true
        moreToolbarItem.menu.delegate = self
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.tabsItem, .space, Self.connectionsItem, .flexibleSpace,
            Self.agentItem, Self.captureItem, Self.searchItem, Self.moreItem,
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
        case Self.tabsItem: tabsToolbarItem
        case Self.connectionsItem: connectionsToolbarItem
        case Self.agentItem: agentToolbarItem
        case Self.captureItem: captureToolbarItem
        case Self.searchItem: searchToolbarItem
        case Self.moreItem: moreToolbarItem
        default: nil
        }
    }
}
