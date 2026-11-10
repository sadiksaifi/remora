import Observation
import RemoraCore
import SwiftUI

/// The UI and command line answer the same pending credential draft.
@MainActor @Observable
final class SessionCredentialDraft {
    var username: String
    var domain: String
    var password: String
    var remember = true

    init(challenge: CredentialsChallenge, password: String) {
        username = challenge.username
        domain = challenge.domain
        self.password = password
    }

    var credentials: SessionCredentials { .init(username: username, domain: domain, password: password) }
}

/// Asks for the account to use when the server needs credentials or rejected the saved ones.
/// It shows the fields the server's sign-in method asks for, and the domain only where the protocol has one.
struct SessionCredentialsView: View {
    let challenge: CredentialsChallenge
    let computerName: String
    let address: String
    let showsDomain: Bool
    let onCancel: () -> Void
    let onConnect: (SessionCredentials, Bool) -> Void
    @Bindable var draft: SessionCredentialDraft
    @FocusState private var focusedField: Field?

    private enum Field {
        case username
        case password
    }

    init(
        challenge: CredentialsChallenge, computerName: String, address: String, showsDomain: Bool,
        draft: SessionCredentialDraft,
        onCancel: @escaping () -> Void, onConnect: @escaping (SessionCredentials, Bool) -> Void
    ) {
        self.challenge = challenge
        self.computerName = computerName
        self.address = address
        self.showsDomain = showsDomain
        self.onCancel = onCancel
        self.onConnect = onConnect
        self.draft = draft
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
                    if asksForUsername {
                        TextField("Username", text: $draft.username)
                            .focused($focusedField, equals: .username)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("credentialsUsername")
                    }
                    KeychainPasswordField(title: "Password", text: $draft.password, prompt: "Required")
                        .focused($focusedField, equals: .password)
                        .accessibilityIdentifier("credentialsPassword")
                    if asksForUsername && showsDomain {
                        TextField("Domain", text: $draft.domain, prompt: Text("Optional"))
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("credentialsDomain")
                    }
                }
                Section {
                    Toggle("Remember this password in my keychain", isOn: $draft.remember)
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
                    onConnect(draft.credentials, draft.remember)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("credentialsConnect")
            }
            .controlSize(.large)
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .onAppear { focusedField = asksForUsername && challenge.username.isEmpty ? .username : .password }
    }

    private var asksForUsername: Bool { challenge.fields == .usernamePassword }

    private var title: String {
        switch challenge.reason {
        case .missing: "Enter your credentials for “\(computerName)”."
        case .rejected: "“\(computerName)” didn’t accept your credentials."
        }
    }

    private var message: String {
        let account = asksForUsername ? "username and password" : "password"
        return switch challenge.reason {
        case .missing: "The remote computer at \(address) needs a \(account)."
        case .rejected: "Check your \(account) for \(address), then try again."
        }
    }
}
