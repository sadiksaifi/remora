import RemoraCore
import SwiftUI

struct SessionCredentialsView: View {
    let challenge: CredentialsChallenge
    let onCancel: () -> Void
    let onConnect: (SessionCredentials, Bool) -> Void
    @State private var username: String
    @State private var password: String
    @State private var domain: String
    @State private var remember = true

    init(challenge: CredentialsChallenge, password: String, onCancel: @escaping () -> Void,
         onConnect: @escaping (SessionCredentials, Bool) -> Void) {
        self.challenge = challenge
        self.onCancel = onCancel
        self.onConnect = onConnect
        _username = State(initialValue: challenge.username)
        _password = State(initialValue: password)
        _domain = State(initialValue: challenge.domain)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(challenge.reason == .rejected ? "The previous credentials were rejected." : "Enter credentials to connect.")
                .padding([.top, .horizontal], 20)
            Form {
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
                TextField("Domain", text: $domain, prompt: Text("Optional"))
                Toggle("Remember password", isOn: $remember)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    onConnect(SessionCredentials(username: username, domain: domain, password: password), remember)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
    }
}
