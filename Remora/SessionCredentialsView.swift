import RemoraCore
import SwiftUI

/// Asks for the account to use when the server needs credentials or rejected the saved ones.
struct SessionCredentialsView: View {
    let challenge: CredentialsChallenge
    let computerName: String
    let address: String
    let onCancel: () -> Void
    let onConnect: (SessionCredentials, Bool) -> Void
    @State private var username: String
    @State private var password: String
    @State private var domain: String
    @State private var remember = true
    @FocusState private var focusedField: Field?

    private enum Field {
        case username
        case password
    }

    init(challenge: CredentialsChallenge, computerName: String, address: String, password: String,
         onCancel: @escaping () -> Void, onConnect: @escaping (SessionCredentials, Bool) -> Void) {
        self.challenge = challenge
        self.computerName = computerName
        self.address = address
        self.onCancel = onCancel
        self.onConnect = onConnect
        _username = State(initialValue: challenge.username)
        _password = State(initialValue: password)
        _domain = State(initialValue: challenge.domain)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding([.top, .horizontal], 20)

            Form {
                Section {
                    TextField("Username", text: $username)
                        .focused($focusedField, equals: .username)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("credentialsUsername")
                    KeychainPasswordField(title: "Password", text: $password, prompt: "Required")
                        .focused($focusedField, equals: .password)
                        .accessibilityIdentifier("credentialsPassword")
                    TextField("Domain", text: $domain, prompt: Text("Optional"))
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("credentialsDomain")
                }
                Section {
                    Toggle("Remember this password in my keychain", isOn: $remember)
                        .accessibilityIdentifier("credentialsRemember")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("credentialsCancel")
                Button("Connect") {
                    onConnect(SessionCredentials(username: username, domain: domain, password: password), remember)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("credentialsConnect")
            }
            .controlSize(.large)
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .onAppear { focusedField = challenge.username.isEmpty ? .username : .password }
    }

    private var title: String {
        switch challenge.reason {
        case .missing: "Enter your credentials for “\(computerName)”."
        case .rejected: "“\(computerName)” didn’t accept your credentials."
        }
    }

    private var message: String {
        switch challenge.reason {
        case .missing: "The remote computer at \(address) needs a username and password."
        case .rejected: "Check your username and password for \(address), then try again."
        }
    }
}
