import AppKit
import RemoraControl
import RemoraCore
import SwiftUI

/// Remora's settings in user defaults. The command line names them captureSystemShortcuts, showAgentPointer
/// and saveLocation; the first is SystemShortcutCapture.enabledKey.
enum AppSettings {
    static let showAgentPointerKey = "ShowAgentPointer"
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
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralPane() }
            Tab("Keyboard", systemImage: "keyboard") { KeyboardPane() }
            Tab("Command Line", systemImage: "terminal") { CommandLinePane() }
        }
    }
}

private extension View {
    /// Every pane is a grouped form, 500 pt wide and as tall as its rows.
    func settingsPane() -> some View {
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
    @AppStorage(AppSettings.saveLocationKey) private var saveLocation = ""
    @State private var choosingFolder = false
    private enum Choice { case current, screenshotLocation, other }

    private var folder: URL { AppSettings.folder(saveLocation) ?? ScreenshotDestination.screenshotLocation }

    var body: some View {
        Form {
            Picker("Save screenshots and recordings to", selection: Binding(get: { Choice.current }, set: { choice in
                switch choice {
                case .current: break
                case .screenshotLocation: saveLocation = ""
                case .other: choosingFolder = true
                }
            })) {
                Label(FileManager.default.displayName(atPath: folder.path), systemImage: "folder").tag(Choice.current)
                Divider()
                Text("Screenshot location").tag(Choice.screenshotLocation)
                Text("Other…").tag(Choice.other)
            }
            .accessibilityIdentifier("saveLocation")
        }
        .settingsPane()
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { saveLocation = url.path }
        }
        .fileDialogDefaultDirectory(folder)
    }
}

private struct KeyboardPane: View {
    @AppStorage(SystemShortcutCapture.enabledKey) private var captureShortcuts = true
    @State private var trusted = SystemShortcutCapture.isTrusted
    private static let captureShortcutsTitle = "Send system shortcuts to the remote computer"

    var body: some View {
        Form {
            Toggle(isOn: $captureShortcuts) {
                Text(Self.captureShortcutsTitle)
                Text("While a session tab is active, shortcuts like Command-Tab and Command-Space go to the remote computer. Command-Q, Control-Command-F, and the Control-Option-Command tab and capture shortcuts stay on this Mac.")
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
        .settingsPane()
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

private struct CommandLinePane: View {
    @AppStorage(AppSettings.showAgentPointerKey) private var showAgentPointer = true
    @State private var state: CommandLineTool.State?
    private let tool = CommandLineTool(target: Bundle.main.bundleURL.appending(path: "Contents/Helpers/remora"))
    private static let pointerTitle = "Show pointer while the command line controls a session"

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    switch state {
                    case .notInstalled: Button("Install") { perform(tool.install) }
                    case .installed: Button("Uninstall") { perform(tool.uninstall) }
                    case .broken: Button("Repair") { perform(tool.repair) }
                    case .conflict: Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([tool.link]) }
                    case nil: EmptyView()
                    }
                } label: {
                    Text("Command-line tool")
                    switch state {
                    case .installed: StatusLabel(text: "Installed at \(tool.displayPath)", ok: true)
                    case .broken:
                        StatusLabel(text: "The link at \(tool.displayPath) points to a copy of Remora that was moved or deleted.", ok: false)
                    case .conflict:
                        StatusLabel(text: CommandLineTool.Failure.conflict(tool.displayPath).localizedDescription, ok: false)
                    case .notInstalled, nil: Text("Not installed")
                    }
                }
                .accessibilityIdentifier("commandLineTool")
                if state == .installed {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(CommandLineTool.pathAdvice)
                        CopyableText(text: CommandLineTool.pathCommand)
                    }
                }
            }
            AgentSkillSection()
            Section {
                Toggle(isOn: $showAgentPointer) {
                    Text(Self.pointerTitle)
                    Text("A blue arrow marks where the command line last pointed or clicked. It never appears in screenshots or recordings.")
                }
                .accessibilityLabel(Self.pointerTitle)
                .accessibilityIdentifier("showAgentPointer")
            }
        }
        .settingsPane()
        .onAppear { state = tool.state }
        // The user may move the file in the way, or the app, while Remora is in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state = tool.state
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { NSApplication.shared.presentError(error) }
        state = tool.state
    }
}

/// Links the bundled agent skill into each detected agent's skills folder.
private struct AgentSkillSection: View {
    @State private var states: [AgentSkill.Agent: CommandLineTool.State] = [:]
    private let skill = AgentSkill(app: Bundle.main.bundleURL)

    private var agents: [AgentSkill.Agent] { AgentSkill.Agent.allCases.filter { states[$0] != nil } }
    private var installable: [AgentSkill.Agent] { agents.filter { states[$0] != .installed && states[$0] != .conflict } }

    var body: some View {
        Section {
            LabeledContent {
                Button("Install for All") { perform { for agent in installable { try skill.link(for: agent).install() } } }
                    .disabled(installable.isEmpty)
                    .accessibilityIdentifier("installAgentSkillForAll")
            } label: {
                Text("Agent skill")
                Text(agents.isEmpty ? "No supported AI agents were found on this Mac." : "Teaches AI agents to use the remora command.")
            }
            ForEach(agents, id: \.self) { agent in
                let link = skill.link(for: agent)
                LabeledContent {
                    switch states[agent] {
                    case .notInstalled: Button("Install") { perform(link.install) }
                    case .installed, .broken: Button("Remove") { perform(link.uninstall) }
                    case .conflict: Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([link.link]) }
                    case nil: EmptyView()
                    }
                } label: {
                    Text(agent.name)
                    switch states[agent] {
                    case .installed, .broken: StatusLabel(text: "Installed at \(link.displayPath)", ok: true)
                    case .conflict: StatusLabel(text: "Another skill is in use at \(link.displayPath).", ok: false)
                    case .notInstalled, nil: Text("Not installed")
                    }
                }
                .accessibilityIdentifier("agentSkill-\(agent.rawValue)")
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("For other agents, link this folder into their skills folder.")
                CopyableText(text: skill.folder.path)
            }
        }
        .onAppear(perform: refresh)
        // The user may install an agent or change its skills folder while Remora is in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        states = Dictionary(uniqueKeysWithValues: AgentSkill.Agent.allCases.filter(\.isDetected).map { ($0, skill.link(for: $0).state) })
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { NSApplication.shared.presentError(error) }
        refresh()
    }
}
