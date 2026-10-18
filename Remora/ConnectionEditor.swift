import RemoraCore
import SwiftUI

/// Sheet form for creating, editing, or duplicating a connection.
/// It only edits a draft; the presenter decides how to save it.
struct ConnectionEditor: View {
    private let title: String
    private let original: Connection
    private let onCancel: () -> Void
    private let onSave: (Connection, String) -> Void

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password: String
    @State private var domain: String
    @State private var resolutionChoice: ResolutionChoice
    @State private var customWidth: String
    @State private var customHeight: String
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

    init(
        title: String,
        connection: Connection,
        password: String,
        onCancel: @escaping () -> Void,
        onSave: @escaping (Connection, String) -> Void
    ) {
        self.title = title
        original = connection
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: connection.name)
        _host = State(initialValue: connection.host)
        _port = State(initialValue: connection.port == Connection.defaultPort ? "" : String(connection.port))
        _username = State(initialValue: connection.username)
        _password = State(initialValue: password)
        _domain = State(initialValue: connection.domain ?? "")
        _resolutionChoice = State(initialValue: ResolutionChoice.allCases.first {
            $0.resolution == connection.resolution
        } ?? .custom)
        if case .fixed(let width, let height) = connection.resolution {
            _customWidth = State(initialValue: String(width))
            _customHeight = State(initialValue: String(height))
        } else {
            _customWidth = State(initialValue: "")
            _customHeight = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.top, 20)
            Form {
                Section {
                    TextField("Host", text: $host, prompt: Text("Name or IP address"))
                        .focused($focusedField, equals: .host)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("editorHost")
                        .accessibilityHint(hostProblem ?? "")
                    TextField("Port", text: $port, prompt: Text(String(Connection.defaultPort)))
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
                    TextField("Domain", text: $domain, prompt: Text("Optional"))
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("editorDomain")
                } header: {
                    Text("Account")
                } footer: {
                    Text("Remora saves the password in your keychain.")
                        .foregroundStyle(.secondary)
                }
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
                Section {
                    TextField("Name", text: $name, prompt: Text(trimmedHost.isEmpty ? "Optional" : trimmedHost))
                        .accessibilityIdentifier("editorName")
                } footer: {
                    Text("Shown in the connections list.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("editorCancel")
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("editorSave")
                    .disabled(draft == nil)
            }
            .controlSize(.large)
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .defaultFocus($focusedField, .host)
    }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPort: String {
        port.trimmingCharacters(in: .whitespaces)
    }

    /// An empty port means the RDP default.
    private var parsedPort: Int? {
        guard !trimmedPort.isEmpty else { return Connection.defaultPort }
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

    private var resolution: ConnectionResolution? {
        if let preset = resolutionChoice.resolution { return preset }
        guard let width = Int(customWidth), let height = Int(customHeight) else { return nil }
        return .fixed(width: width, height: height)
    }

    private var resolutionProblem: String? {
        guard resolutionChoice == .custom, resolution?.isValid != true else { return nil }
        return "Enter a width and height from 200 to 8192 pixels. Width must be even."
    }

    /// The edited connection, or nil while the host is empty or the address is invalid.
    private var draft: Connection? {
        guard !trimmedHost.isEmpty, hostProblem == nil, let port = parsedPort,
              let resolution, resolution.isValid else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        var connection = original
        connection.resolution = resolution
        connection.name = trimmedName.isEmpty ? trimmedHost : trimmedName
        connection.host = trimmedHost
        connection.port = port
        connection.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.domain = trimmedDomain.isEmpty ? nil : trimmedDomain
        return connection
    }

    private func save() {
        guard let draft else { return }
        onSave(draft, password)
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
            .font(.callout)
    }
}
