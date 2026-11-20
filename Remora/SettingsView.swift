import AppKit
import RemoraControl
import RemoraCore
import SwiftUI

/// Remora's settings in user defaults, also exposed by the command line.
enum AppSettings {
    static let showAgentPointerKey = "ShowAgentPointer"
    static let showPointerInRecordingsKey = "ShowPointerInRecordings"
    static let showKeyPressesKey = "ShowKeyPresses"
    static var showAgentPointer: Bool { UserDefaults.standard.object(forKey: showAgentPointerKey) as? Bool ?? true }
    static var showPointerInRecordings: Bool { UserDefaults.standard.object(forKey: showPointerInRecordingsKey) as? Bool ?? true }
    static var showKeyPresses: Bool { UserDefaults.standard.bool(forKey: showKeyPressesKey) }
    /// A multiple of the key press display's standard size, within `KeyPressPill.sizes`.
    static let keyPressSizeKey = "KeyPressSize"
    static var keyPressSize: Double { UserDefaults.standard.object(forKey: keyPressSizeKey) as? Double ?? 1 }
    /// A folder path. Empty means the macOS screenshot location.
    static let saveLocationKey = "SaveLocation"

    /// The folder for screenshots and recordings, or nil for the macOS screenshot location.
    static var saveFolder: URL? { folder(UserDefaults.standard.string(forKey: saveLocationKey) ?? "") }

    static func folder(_ path: String) -> URL? {
        path.isEmpty ? nil : URL(filePath: path, directoryHint: .isDirectory)
    }
}

extension NSApplication {
    /// SwiftUI gives the Settings scene's window this identifier.
    var settingsWindow: NSWindow? { windows.first { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" } }
}

/// The Settings scene's content. It holds only settings that change existing behavior.
struct SettingsView: View {
    /// False in a build without updates, such as Remora Dev.
    let showsUpdates: Bool

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralPane(showsUpdates: showsUpdates) }
            Tab("Command Line", systemImage: "terminal") { CommandLinePane() }
        }
    }
}

extension View {
    /// Every pane is a grouped form, 500 pt wide and as tall as its rows.
    fileprivate func settingsPane() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 500)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row's status line: a green or orange symbol and secondary text.
private struct StatusLabel: View {
    let text: String
    let ok: Bool

    var body: some View {
        Label {
            // Match the secondary line a form gives a second Text.
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
        }
    }
}

private struct GeneralPane: View {
    let showsUpdates: Bool
    @AppStorage(AppUpdater.automaticChecksKey) private var checkForUpdates = false
    @AppStorage(AppUpdater.automaticDownloadsKey) private var installUpdates = false
    @AppStorage(SystemShortcutCapture.enabledKey) private var captureShortcuts = true
    @AppStorage(AppSettings.showKeyPressesKey) private var showKeyPresses = false
    @AppStorage(AppSettings.keyPressSizeKey) private var keyPressSize = 1.0
    @AppStorage(AppSettings.saveLocationKey) private var saveLocation = ""
    @AppStorage(AppSettings.showPointerInRecordingsKey) private var showPointer = true
    @State private var trusted = SystemShortcutCapture.isTrusted
    @State private var choosingFolder = false
    private enum Choice { case current, screenshotLocation, other }
    private static let captureShortcutsTitle = "Send system shortcuts to the remote computer"
    private static let keyPressesTitle = "Show key presses"
    private static let pointerTitle = "Show pointer in recordings"

    private var folder: URL { AppSettings.folder(saveLocation) ?? ScreenshotDestination.screenshotLocation }

    var body: some View {
        Form {
            Section("Keyboard") {
                Toggle(isOn: $captureShortcuts) {
                    Text(Self.captureShortcutsTitle)
                    Text(
                        "While a session tab is active, shortcuts like Command-Tab and Command-Space go to the remote computer. Command-Q, Control-Command-F, and the Control-Option-Command tab and capture shortcuts stay on this Mac."
                    )
                }
                // The form shows the label beside the switch; this puts it on the switch itself.
                .accessibilityLabel(Self.captureShortcutsTitle)
                .accessibilityIdentifier("captureSystemShortcuts")
                LabeledContent {
                    Button("Open System Settings") { SystemShortcutCapture.openAccessibilitySettings() }
                        .accessibilityIdentifier("openAccessibilitySettings")
                } label: {
                    Text("Permission to control this Mac")
                    StatusLabel(text: trusted ? "Allowed" : "Not allowed. System shortcuts stay on this Mac.", ok: trusted)
                        .accessibilityIdentifier("accessibilityPermission")
                }
                .disabled(!captureShortcuts)
            }
            Section {
                Toggle(isOn: $showKeyPresses) {
                    Text(Self.keyPressesTitle)
                    Text("Typed text, including passwords, appears on screen and in recordings.")
                }
                .accessibilityLabel(Self.keyPressesTitle)
                .accessibilityIdentifier("showKeyPresses")
                // Like the Dock's size slider: small and large glyphs at the ends, snapping to quarter steps.
                Slider(value: $keyPressSize, in: KeyPressPill.sizes, step: 0.25) {
                    Text("Size")
                } minimumValueLabel: {
                    Image(systemName: "textformat.size.smaller").accessibilityLabel("Small")
                } maximumValueLabel: {
                    Image(systemName: "textformat.size.larger").accessibilityLabel("Large")
                }
                .disabled(!showKeyPresses)
                .accessibilityIdentifier("keyPressSize")
            }
            Section("Screenshots and Recordings") {
                Picker(
                    "Save screenshots and recordings to",
                    selection: Binding(
                        get: { Choice.current },
                        set: { choice in
                            switch choice {
                            case .current: break
                            case .screenshotLocation: saveLocation = ""
                            case .other: choosingFolder = true
                            }
                        })
                ) {
                    Label(FileManager.default.displayName(atPath: folder.path), systemImage: "folder").tag(Choice.current)
                    Divider()
                    Text("Screenshot location").tag(Choice.screenshotLocation)
                    Text("Other…").tag(Choice.other)
                }
                .accessibilityIdentifier("saveLocation")
                Toggle(isOn: $showPointer) {
                    Text(Self.pointerTitle)
                    Text("Recordings show your pointer with a ring on each click, and the command line's cursor. Screenshots never do.")
                }
                .accessibilityLabel(Self.pointerTitle)
                .accessibilityIdentifier("showPointerInRecordings")
            }
            if showsUpdates {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: $checkForUpdates)
                        .accessibilityIdentifier("checkForUpdates")
                    Toggle("Download and install updates automatically", isOn: $installUpdates)
                        .disabled(!checkForUpdates)
                        .accessibilityIdentifier("installUpdates")
                }
            }
        }
        .settingsPane()
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { saveLocation = url.path }
        }
        .fileDialogDefaultDirectory(folder)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = SystemShortcutCapture.isTrusted
        }
    }
}

/// Monospaced, selectable text in a field-like box with a Copy button.
private struct CopyableText: View {
    let text: String

    var body: some View {
        HStack {
            Text(text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
    }
}

/// A link's status in one short line. The help tag holds the paths.
private struct LinkStatus: View {
    let link: CommandLineTool
    let state: CommandLineTool.State?

    var body: some View {
        switch state {
        case .notInstalled, nil: Text(CommandLineTool.State.notInstalled.summary)
        case let state?:
            StatusLabel(text: state.summary, ok: state == .installed)
                .help([.installed, .conflict].contains(state) ? link.displayPath : "\(link.displayPath) points to \(link.displayDestination)")
        }
    }
}

/// The one button that resolves a link that isn't this copy's. Replacing another app's or tool's link takes confirmation.
private struct LinkFixButton: View {
    let link: CommandLineTool
    let state: CommandLineTool.State
    let perform: (() throws -> Void) -> Void
    @State private var confirmsReplace = false
    @State private var shownDestination = ""

    var body: some View {
        switch state {
        case .otherCopy: Button("Update") { perform { try link.install() } }
        case .broken: Button("Repair") { perform { try link.install() } }
        case .otherLink:
            Button("Replace…") {
                shownDestination = link.displayDestination
                confirmsReplace = true
            }
            .alert("Replace the link at \(link.displayPath)?", isPresented: $confirmsReplace) {
                Button("Replace", role: .destructive) {
                    // If the link changed while the alert was open, the row only shows its new state.
                    perform { if link.displayDestination == shownDestination { try link.install(replacingOtherLink: true) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It points to \(shownDestination), which belongs to another app or tool. That file stays unchanged.")
            }
        case .conflict: Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([link.link]) }
        case .notInstalled, .installed: EmptyView()
        }
    }
}

private struct CommandLinePane: View {
    @AppStorage(AppSettings.showAgentPointerKey) private var showAgentPointer = true
    @State private var state: CommandLineTool.State?
    @State private var showsPathAdvice = false
    @State private var isOnPath: Bool?
    @State private var opensPathAdvice = false
    private let tool = CommandLineTool()
    private static let pointerTitle = "Show pointer while the command line controls a session"

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    switch state {
                    case .notInstalled:
                        Button("Install") {
                            perform { try tool.install() }
                            opensPathAdvice = state == .installed
                        }
                    case .installed:
                        HStack {
                            // Row-specific help opens from an info button, as in System Settings.
                            Button("PATH Setup", systemImage: "info.circle") { showsPathAdvice.toggle() }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help("PATH Setup")
                                .popover(isPresented: $showsPathAdvice, arrowEdge: .bottom) {
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(CommandLineTool.pathAdvice)
                                        CopyableText(text: CommandLineTool.pathCommand)
                                    }
                                    .padding()
                                }
                            Button("Uninstall") { perform { try tool.uninstall() } }
                        }
                    case let state?: LinkFixButton(link: tool, state: state, perform: perform)
                    case nil: EmptyView()
                    }
                } label: {
                    Text("Command-line tool")
                    if state == .installed, isOnPath == false {
                        StatusLabel(text: "Installed, but not on your PATH", ok: false)
                            .help("~/.local/bin isn't on your PATH, so \(tool.link.lastPathComponent) won't run in Terminal.")
                    } else {
                        LinkStatus(link: tool, state: state)
                    }
                }
                .accessibilityIdentifier("commandLineTool")
                .task(id: state) {
                    isOnPath = nil
                    guard state == .installed else { return }
                    isOnPath = await tool.isOnShellPath()
                    if isOnPath == false, opensPathAdvice { showsPathAdvice = true }
                    opensPathAdvice = false
                }
            }
            AgentSkillSection()
            Section {
                Toggle(isOn: $showAgentPointer) {
                    Text(Self.pointerTitle)
                    Text("It never appears in screenshots.")
                }
                .accessibilityLabel(Self.pointerTitle)
                .accessibilityIdentifier("showAgentPointer")
            }
        }
        .settingsPane()
        // The command line, Finder or another app may change the link while the pane is open.
        .task { repeat { state = tool.state } while (try? await Task.sleep(for: .seconds(1))) != nil }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { NSApplication.shared.presentError(error) }
        state = tool.state
    }
}

/// Links the bundled agent skill into the shared Agent Skills folder and Claude Code's skills folder.
private struct AgentSkillSection: View {
    @State private var states: [AgentSkill.Folder: CommandLineTool.State] = [:]
    @State private var otherAgentsExpanded = false
    private let skill = AgentSkill()

    var body: some View {
        Section {
            LabeledContent {
            } label: {
                Text("Agent skill")
                Text("Teaches AI agents to use the \(AppIdentity.current.commandName) command.")
            }
            ForEach(AgentSkill.Folder.allCases, id: \.self) { folder in
                let link = skill.link(in: folder)
                LabeledContent {
                    switch states[folder] {
                    case .notInstalled: Button("Install") { perform { try link.install() } }
                    case .installed: Button("Remove") { perform { try link.uninstall() } }
                    case let state?: LinkFixButton(link: link, state: state, perform: perform)
                    case nil: EmptyView()
                    }
                } label: {
                    Text(folder.name)
                    // One subtitle view, so the status line has the same style in both rows.
                    VStack(alignment: .leading, spacing: 2) {
                        if folder == .agents { Text("Read by Codex, OpenCode, Cursor and other agents.") }
                        LinkStatus(link: link, state: states[folder])
                    }
                }
                .accessibilityIdentifier("agentSkill-\(folder.rawValue)")
            }
            DisclosureGroup("Other agents", isExpanded: $otherAgentsExpanded) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Link this folder into the agent's skills folder.")
                    CopyableText(text: skill.folder.path)
                }
            }
            .accessibilityAction { otherAgentsExpanded.toggle() }
        }
        // The command line, Finder or another app may change a skills folder while the pane is open.
        .task { repeat { refresh() } while (try? await Task.sleep(for: .seconds(1))) != nil }
    }

    private func refresh() {
        states = Dictionary(uniqueKeysWithValues: AgentSkill.Folder.allCases.map { ($0, skill.link(in: $0).state) })
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { NSApplication.shared.presentError(error) }
        refresh()
    }
}
