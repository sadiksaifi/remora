import RemoraCore
import SwiftUI

/// Sheet form for creating, editing, or duplicating a connection.
/// It only edits a draft; the presenter decides how to save it.
struct ConnectionEditor: View {
    private let title: String
    private let original: Connection
    private let originalPassword: String
    private let onCancel: () -> Void
    private let onSave: (Connection, String) -> Void
    private let onConnect: ((Connection, String) -> Void)?
    private let identifyVNCServer: (@Sendable (String, Int) async -> VNCMode?)?

    @State private var kind: Connection.Kind
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password: String
    @State private var domain: String
    @State private var resolutionChoice: ResolutionChoice
    @State private var customWidth: String
    @State private var customHeight: String
    @State private var vncMode: VNCMode
    /// Detection never overrides a mode the user picked.
    @State private var vncModeChosen = false
    /// The address whose greeting came from a Mac. It applies only while the fields still show that address.
    @State private var detectedMac: ServerAddress?
    /// The address whose check finished, whatever it found.
    @State private var identifiedServer: ServerAddress?
    /// Connect waiting for the check of the address it is about to open.
    @State private var connecting: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    private enum ResolutionChoice: String, CaseIterable {
        case fitToWindow = "Fit to Window"
        case hd = "1280 × 720"
        case fullHD = "1920 × 1080"
        case quadHD = "2560 × 1440"
        case custom = "Custom"

        var resolution: ConnectionResolution? {
            switch self {
            case .fitToWindow: .fitToWindow
            case .hd: .fixed(width: 1280, height: 720)
            case .fullHD: .fixed(width: 1920, height: 1080)
            case .quadHD: .fixed(width: 2560, height: 1440)
            case .custom: nil
            }
        }
    }

    private enum Field {
        case host
    }

    private struct ServerAddress: Equatable {
        let host: String
        let port: Int
    }

    /// With `identifyVNCServer`, the editor reads a VNC server's greeting and picks Apple mode for a Mac.
    /// Pass it only for a new connection, so a saved or copied mode never changes behind the user's back.
    /// With `onConnect`, the sheet adds a Connect button, which is then the default instead of Save.
    init(
        title: String,
        connection: Connection,
        password: String,
        identifyVNCServer: (@Sendable (String, Int) async -> VNCMode?)? = nil,
        onCancel: @escaping () -> Void,
        onSave: @escaping (Connection, String) -> Void,
        onConnect: ((Connection, String) -> Void)? = nil
    ) {
        self.title = title
        original = connection
        originalPassword = password
        self.identifyVNCServer = identifyVNCServer
        self.onCancel = onCancel
        self.onSave = onSave
        self.onConnect = onConnect
        _kind = State(initialValue: connection.kind)
        _name = State(initialValue: connection.name)
        _host = State(initialValue: connection.host)
        _port = State(initialValue: Self.portText(for: connection))
        _username = State(initialValue: connection.username)
        _password = State(initialValue: password)
        _domain = State(initialValue: connection.domain ?? "")
        _resolutionChoice = State(
            initialValue: ResolutionChoice.allCases.first {
                $0.resolution == connection.resolution
            } ?? .custom)
        if case .fixed(let width, let height) = connection.resolution {
            _customWidth = State(initialValue: String(width))
            _customHeight = State(initialValue: String(height))
        } else {
            _customWidth = State(initialValue: "")
            _customHeight = State(initialValue: "")
        }
        _vncMode = State(initialValue: connection.vncMode)
    }

    /// An empty port field means the protocol's default port.
    private static func portText(for connection: Connection) -> String {
        connection.port == connection.kind.defaultPort ? "" : String(connection.port)
    }

    /// Settings and the password belong to one protocol, so switching resets them to the new
    /// protocol's defaults. Switching back restores the connection's saved values.
    private func protocolChanged(to kind: Connection.Kind) {
        let restores = kind == original.kind
        port = restores ? Self.portText(for: original) : ""
        password = restores ? originalPassword : ""
        domain = restores ? original.domain ?? "" : ""
        let resolution = restores ? original.resolution : .fitToWindow
        resolutionChoice = ResolutionChoice.allCases.first { $0.resolution == resolution } ?? .custom
        if case .fixed(let width, let height) = resolution {
            customWidth = String(width)
            customHeight = String(height)
        }
        vncMode = restores ? original.vncMode : .standard
        // The reset discards the user's pick, so detection resumes.
        vncModeChosen = false
        detectedMac = nil
        identifiedServer = nil
    }

    /// The address in the fields, or nil while it is incomplete or invalid.
    private var serverAddress: ServerAddress? {
        guard !trimmedHost.isEmpty, hostProblem == nil, let port = parsedPort else { return nil }
        return ServerAddress(host: trimmedHost, port: port)
    }

    /// The address to check for a Mac, or nil when there is nothing to check.
    private var serverToIdentify: ServerAddress? {
        guard identifyVNCServer != nil, kind == .vnc, !vncModeChosen else { return nil }
        return serverAddress
    }

    /// True while the fields show the address of a detected Mac and the user has not picked a mode.
    private var macDetected: Bool {
        !vncModeChosen && detectedMac != nil && detectedMac == serverAddress
    }

    /// The mode shown and saved. Editing the address drops a detected Mac's Apple mode at once.
    private var effectiveVNCMode: VNCMode {
        macDetected ? .apple : vncMode
    }

    private func identify(_ server: ServerAddress?) async {
        guard let server, let identifyVNCServer else { return }
        // Wait for typing to pause, so Remora does not connect to every partial host name.
        guard (try? await Task.sleep(for: .milliseconds(600))) != nil else { return }
        let mode = await identifyVNCServer(server.host, server.port)
        guard !Task.isCancelled else { return }
        detectedMac = mode == .apple ? server : nil
        identifiedServer = server
    }

    /// Connect opens the connection with the saved mode at once, so it first finishes the check of the
    /// address in the fields. Save leaves an unfinished check alone, as the mode can still be edited.
    private func connect(with open: @escaping (Connection, String) -> Void) {
        guard let server = serverToIdentify, server != identifiedServer, let identifyVNCServer else {
            return submit(to: open)
        }
        connecting = Task {
            let mode = await identifyVNCServer(server.host, server.port)
            guard !Task.isCancelled else { return }
            detectedMac = mode == .apple ? server : nil
            identifiedServer = server
            connecting = nil
            submit(to: open)
        }
    }

    /// The user's own pick ends detection for this sheet.
    private var chosenVNCMode: Binding<VNCMode> {
        Binding(
            get: { effectiveVNCMode },
            set: {
                vncMode = $0
                vncModeChosen = true
            })
    }

    /// The password field is cleared, and Save removes a stored password.
    private var removesSavedPassword: Bool {
        kind != original.kind && !originalPassword.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.top, 20)
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text(trimmedHost.isEmpty ? "Optional" : trimmedHost))
                        .accessibilityIdentifier("editorName")
                }
                Section {
                    Picker("Protocol", selection: $kind) {
                        ForEach([Connection.Kind.rdp, .vnc], id: \.self) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("editorProtocol")
                    .onChange(of: kind) { _, kind in protocolChanged(to: kind) }
                    TextField("Host", text: $host, prompt: Text("Name or IP address"))
                        .focused($focusedField, equals: .host)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("editorHost")
                        .accessibilityHint(hostProblem ?? "")
                    TextField("Port", text: $port, prompt: Text(String(kind.defaultPort)))
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("editorPort")
                        .accessibilityHint(portProblem ?? "")
                } header: {
                    Text("Connection")
                } footer: {
                    if hostProblem != nil || portProblem != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            if let hostProblem {
                                ValidationMessage(hostProblem).accessibilityIdentifier("editorHostProblem")
                            }
                            if let portProblem {
                                ValidationMessage(portProblem).accessibilityIdentifier("editorPortProblem")
                            }
                        }
                    }
                }
                Section {
                    TextField("Username", text: $username, prompt: Text("Optional"))
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("editorUsername")
                    KeychainPasswordField(title: "Password", text: $password)
                        .accessibilityIdentifier("editorPassword")
                    if kind == .rdp {
                        TextField("Domain", text: $domain, prompt: Text("Optional"))
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("editorDomain")
                    }
                } header: {
                    Text("Account")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if removesSavedPassword {
                            Label {
                                Text("Changing the protocol clears the password.").foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                            }
                            .accessibilityIdentifier("editorPasswordRemoved")
                        }
                        Text(
                            kind == .vnc
                                ? "Some VNC servers ask only for a password. Remora saves the password in your keychain."
                                : "Remora saves the password in your keychain."
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                if kind == .vnc {
                    Section {
                        Picker("Mode", selection: chosenVNCMode) {
                            Text("Standard").tag(VNCMode.standard)
                            Text("Apple Screen Sharing").tag(VNCMode.apple)
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("editorVNCMode")
                    } header: {
                        Text("Display")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            if macDetected {
                                Text("This server looks like a Mac, so Remora chose Apple Screen Sharing.")
                                    .accessibilityIdentifier("editorMacDetected")
                            }
                            Text(
                                effectiveVNCMode == .apple
                                    ? "Encrypted. Works only with Screen Sharing on a Mac and uses your Mac account password."
                                    : "Works with most VNC servers. Screen Sharing on a Mac isn’t encrypted in this mode."
                            )
                        }
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Picker("Resolution", selection: $resolutionChoice) {
                            ForEach(ResolutionChoice.allCases, id: \.self) { choice in
                                Text(choice.rawValue).tag(choice)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("editorResolution")
                        .onChange(of: resolutionChoice) { previous, current in
                            guard current == .custom else { return }
                            if case .fixed(let width, let height) = previous.resolution {
                                customWidth = String(width)
                                customHeight = String(height)
                            } else {
                                let screen = NSApp.keyWindow?.screen ?? NSScreen.main
                                let size = screen?.frame.size ?? NSSize(width: 1440, height: 900)
                                customWidth = String(Int(size.width))
                                customHeight = String(Int(size.height))
                            }
                        }
                        if resolutionChoice == .custom {
                            LabeledContent("Size") {
                                HStack(spacing: 6) {
                                    TextField("Width", text: $customWidth)
                                        .labelsHidden()
                                        .accessibilityIdentifier("editorWidth")
                                        .accessibilityHint(resolutionProblem ?? "")
                                    Text("×")
                                    TextField("Height", text: $customHeight)
                                        .labelsHidden()
                                        .accessibilityIdentifier("editorHeight")
                                        .accessibilityHint(resolutionProblem ?? "")
                                    Text("pixels").foregroundStyle(.secondary)
                                }
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 230)
                            }
                        }
                    } header: {
                        Text("Display")
                    } footer: {
                        if let resolutionProblem {
                            ValidationMessage(resolutionProblem).accessibilityIdentifier("editorResolutionProblem")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(connecting != nil)

            HStack {
                if connecting != nil { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) {
                    connecting?.cancel()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("editorCancel")
                Button("Save") { submit(to: onSave) }
                    .keyboardShortcut(onConnect == nil ? .defaultAction : nil)
                    .accessibilityIdentifier("editorSave")
                    .disabled(draft == nil || connecting != nil)
                if let onConnect {
                    Button("Connect") { connect(with: onConnect) }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("editorConnect")
                        .disabled(draft == nil || connecting != nil)
                }
            }
            .controlSize(.large)
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        // The optional name comes first, but typing starts in Host.
        .onAppear { focusedField = .host }
        .task(id: serverToIdentify) { await identify(serverToIdentify) }
    }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPort: String {
        port.trimmingCharacters(in: .whitespaces)
    }

    /// An empty port means the protocol's default.
    private var parsedPort: Int? {
        guard !trimmedPort.isEmpty else { return kind.defaultPort }
        guard let value = Int(trimmedPort), (1...65535).contains(value) else { return nil }
        return value
    }

    /// Shown only for input the user has typed; an empty host just disables Save.
    private var hostProblem: String? {
        guard trimmedHost.contains(where: \.isWhitespace) || trimmedHost.contains("/") else { return nil }
        return "Enter a host name or IP address without spaces or slashes."
    }

    private var portProblem: String? {
        parsedPort == nil ? "Enter a port from 1 to 65535." : nil
    }

    /// The server sets a VNC desktop's size; Remora follows the window when the server allows it.
    private var resolution: ConnectionResolution? {
        if kind == .vnc { return .fitToWindow }
        if let preset = resolutionChoice.resolution { return preset }
        guard let width = Int(customWidth), let height = Int(customHeight) else { return nil }
        return .fixed(width: width, height: height)
    }

    private var resolutionProblem: String? {
        guard kind == .rdp, resolutionChoice == .custom, resolution?.isValid != true else { return nil }
        return "Enter a width and height from 200 to 8192 pixels. Width must be even."
    }

    /// The edited connection, or nil while the host is empty or the address is invalid.
    private var draft: Connection? {
        guard !trimmedHost.isEmpty, hostProblem == nil, let port = parsedPort,
            let resolution, resolution.isValid
        else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        var connection = original
        connection.kind = kind
        connection.resolution = resolution
        connection.name = trimmedName.isEmpty ? trimmedHost : trimmedName
        connection.host = trimmedHost
        connection.port = port
        connection.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.domain = kind == .rdp && !trimmedDomain.isEmpty ? trimmedDomain : nil
        connection.vncMode = kind == .vnc ? effectiveVNCMode : .standard
        return connection
    }

    private func submit(to receive: (Connection, String) -> Void) {
        guard let draft else { return }
        receive(draft, password)
    }
}

/// An inline validation message under a form section.
struct ValidationMessage: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .foregroundStyle(.red)
    }
}
