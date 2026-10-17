import RemoraCore
import SwiftUI

/// Sheet form for creating, editing, or duplicating a connection.
/// It only edits a draft; the presenter decides how to save it.
struct ConnectionEditor: View {
    private let original: Connection
    private let onCancel: () -> Void
    private let onSave: (Connection, String) -> Void

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password: String
    @State private var domain: String

    init(
        connection: Connection,
        password: String,
        onCancel: @escaping () -> Void,
        onSave: @escaping (Connection, String) -> Void
    ) {
        original = connection
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: connection.name)
        _host = State(initialValue: connection.host)
        _port = State(initialValue: String(connection.port))
        _username = State(initialValue: connection.username)
        _password = State(initialValue: password)
        _domain = State(initialValue: connection.domain ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text(trimmedHost.isEmpty ? "Optional" : trimmedHost))
                }
                Section {
                    TextField("Host", text: $host, prompt: Text("Required"))
                    TextField("Port", text: $port, prompt: Text("3389"))
                }
                Section {
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                    TextField("Domain", text: $domain, prompt: Text("Optional"))
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
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
    }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The edited connection, or nil while Host is empty or Port is outside 1-65535.
    private var draft: Connection? {
        guard !trimmedHost.isEmpty,
              let port = Int(port.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(port)
        else { return nil }
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
