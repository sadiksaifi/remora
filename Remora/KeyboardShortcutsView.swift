import RemoraControl
import SwiftUI

/// The Keyboard Shortcuts window: the shortcuts that stay on this Mac while a session has the keyboard,
/// and what the modifier keys send. The menus define the shortcuts. This list repeats them for reading.
struct KeyboardShortcutsView: View {
    private struct Group {
        let title: String
        let rows: [(name: String, keys: String)]
    }

    private static let leading = [
        Group(
            title: "Tabs",
            rows: [
                ("Connections", "⌃⌥⌘H"),
                ("Show Previous Tab", "⌃⌥⌘["),
                ("Show Next Tab", "⌃⌥⌘]"),
                ("Show Tab 1 Through 9", "⌃⌥⌘1 – 9"),
                ("Close Tab", "⌃⌥⌘W"),
            ]),
        Group(
            title: "Displays",
            rows: [
                ("Show Next Display", "⌃⌥⌘→"),
                ("Show Previous Display", "⌃⌥⌘←"),
            ]),
    ]

    private static let trailing = [
        Group(
            title: "Capture",
            rows: [
                ("Take Screenshot", "⌃⌥⌘S"),
                ("Copy Screenshot", "⌃⌥⇧⌘S"),
                ("Start or Stop Recording", "⌃⌥⌘R"),
            ]),
        Group(
            title: "Session",
            rows: [
                ("Release Keyboard Capture", "⌃⌥⌘⎋"),
                ("Enter or Exit Full Screen", "⌃⌘F"),
                ("Quit \(AppIdentity.current.name)", "⌘Q"),
            ]),
        Group(
            title: "Modifier Keys in a Session",
            rows: [
                ("Command", "Windows or Super"),
                ("Control", "Control"),
                ("Option", "Alt"),
            ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("These shortcuts stay on this Mac while a session has the keyboard.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
                .padding(.top, 16)
            HStack(alignment: .top, spacing: 0) {
                column(Self.leading)
                column(Self.trailing)
            }
        }
        .frame(width: 800)
    }

    private func column(_ groups: [Group]) -> some View {
        Form {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.rows, id: \.name) { row in
                        LabeledContent(row.name, value: row.keys)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}
