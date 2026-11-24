import RemoraCore
import SwiftUI

/// The agent control in the toolbar, shown from the moment a command-line program takes a session's input.
/// Take Over is blue while the program has the input. Resume is neutral once the person took over or stopped it.
struct AgentControlButton: View {
    var state = SessionControl.State.idle
    /// A hand-over waits for the program's input to end. The button shows a spinner and takes no click.
    var isTransferring = false
    var agent = ""
    var isEnabled = false
    /// False in a narrow window, where the button keeps only its icon.
    var showsTitle = true
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isTransferring {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: takesOver ? "pointer.arrow.motionlines" : "play.fill")
                }
                if showsTitle { Text(takesOver ? "Take Over" : "Resume") }
            }
        }
        .buttonStyle(PillStyle(isProminent: takesOver && !isTransferring, showsTitle: showsTitle))
        // The toolbar's capsule shows around the pill on every side.
        .padding(.horizontal, 2)
        .disabled(!isEnabled || isTransferring)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("agentControlButton")
    }

    private var takesOver: Bool { state == .active }

    private var accessibilityLabel: String {
        if isTransferring { return "Taking over from \(agent)" }
        return takesOver ? "Take Over from \(agent)" : "Resume \(agent)"
    }

    /// A 32 pt pill inside the toolbar's glass capsule: blue for Take Over, bare for Resume.
    /// The toolbar restyles stock button styles as plain toolbar buttons, so the pill is drawn here.
    private struct PillStyle: ButtonStyle {
        let isProminent: Bool
        let showsTitle: Bool
        @Environment(\.isEnabled) private var isEnabled

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: NSFont.systemFontSize, weight: .medium))
                .foregroundStyle(isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.leading, showsTitle ? 11 : 12)
                .padding(.trailing, showsTitle ? 14 : 12)
                .frame(height: 32)
                .background { if isProminent { Capsule().fill(Color(nsColor: .systemBlue)) } }
                .contentShape(Capsule())
                .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
        }
    }
}

/// The short note under the agent button when a program takes control or its control stops.
struct AgentControlCallout: View {
    enum Kind { case inControl, stopped }

    let kind: Kind
    let agent: String

    var title: String {
        switch kind {
        case .inControl: "\(agent) is in control"
        case .stopped: "Agent control stopped"
        }
    }

    private var message: String {
        switch kind {
        case .inControl: "Click Take Over to use the session yourself."
        case .stopped: "\(agent) can no longer control this session."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.semibold)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 236, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agentControlCallout")
    }
}
