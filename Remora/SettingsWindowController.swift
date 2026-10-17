import AppKit
import SwiftUI

/// The Settings window. It holds only settings that change existing behavior.
@MainActor
final class SettingsWindowController: NSWindowController {
    init() {
        let controller = NSHostingController(rootView: SettingsView())
        controller.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: controller)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenNone)
        window.setFrameAutosaveName("Settings")
        super.init(window: window)
        if !window.setFrameUsingName("Settings") { window.center() }
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }
}

private struct SettingsView: View {
    @AppStorage("CaptureSystemShortcuts") private var captureShortcuts = true
    @State private var trusted = SystemShortcutCapture.isTrusted

    var body: some View {
        Form {
            Section("Keyboard") {
                Toggle(isOn: $captureShortcuts) {
                    Text("Send system shortcuts to the remote computer")
                    Text("While a session window is active, shortcuts like Command-Tab and Command-Space go to the remote computer. Command-Q, Control-Command-F, and Control-Option-Command-Escape stay on this Mac.")
                }
                LabeledContent {
                    Button("Open System Settings") { SystemShortcutCapture.openAccessibilitySettings() }
                } label: {
                    Text("Accessibility access")
                    Label(trusted ? "Allowed" : "Not allowed. System shortcuts stay on this Mac.",
                          systemImage: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(trusted ? .green : .orange)
                }
                .disabled(!captureShortcuts)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = SystemShortcutCapture.isTrusted
        }
    }
}
