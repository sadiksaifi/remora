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
    @FocusState private var focusedField: Field?

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
                    TextField("Port", text: $port, prompt: Text(String(Connection.defaultPort)))
                        .autocorrectionDisabled()
                } header: {
                    Text("Computer")
                } footer: {
                    if !addressProblems.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(addressProblems, id: \.self, content: ValidationMessage.init)
                        }
                    }
                }
                Section {
                    TextField("Username", text: $username, prompt: Text("Optional"))
                        .autocorrectionDisabled()
                    KeychainPasswordField(title: "Password", text: $password)
                    TextField("Domain", text: $domain, prompt: Text("Optional"))
                        .autocorrectionDisabled()
                } header: {
                    Text("Account")
                } footer: {
                    Text("Remora saves the password in your keychain.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    TextField("Name", text: $name, prompt: Text(trimmedHost.isEmpty ? "Optional" : trimmedHost))
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
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
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
    private var addressProblems: [String] {
        var problems: [String] = []
        if trimmedHost.contains(where: \.isWhitespace) || trimmedHost.contains("/") {
            problems.append("Enter a host name or IP address without spaces or slashes.")
        }
        if parsedPort == nil {
            problems.append("Enter a port from 1 to 65535.")
        }
        return problems
    }

    /// The edited connection, or nil while the host is empty or the address is invalid.
    private var draft: Connection? {
        guard !trimmedHost.isEmpty, addressProblems.isEmpty, let port = parsedPort else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        var connection = original
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
