import SwiftUI

/// A password field for a secret Remora keeps in its own keychain item.
/// Passwords AutoFill offers website logins for any secure field next to a username field.
/// The one-time-code content type opts this field out of that heuristic; nil and custom types do not.
struct KeychainPasswordField: View {
    let title: String
    @Binding var text: String
    var prompt = "Optional"

    var body: some View {
        SecureField(title, text: $text, prompt: Text(prompt))
            .textContentType(.oneTimeCode)
    }
}
