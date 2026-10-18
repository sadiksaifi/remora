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
    private static let captureShortcutsTitle = "Send system shortcuts to the remote computer"

    var body: some View {
        Form {
            Section("Keyboard") {
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
                    Label(trusted ? "Allowed" : "Not allowed. System shortcuts stay on this Mac.",
                          systemImage: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(trusted ? .green : .orange)
                        .accessibilityIdentifier("accessibilityPermission")
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
