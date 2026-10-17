import RemoraCore
import SwiftUI

/// The tabs inside the toolbar's glass capsule. The toolbar draws the capsule around this view and
/// centers it; the window controller limits its width to `idealWidth(forTabCount:)`.
/// The shown tab sits on a raised pill. Tabs share the width equally and scroll only when
/// they would be narrower than `minimumTabWidth`.
struct SessionTabStrip: View {
    static let idealTabWidth: CGFloat = 220
    static let minimumTabWidth: CGFloat = 76
    static let height: CGFloat = 30
    private static let inset: CGFloat = 3
    fileprivate nonisolated static let coordinateSpace = "SessionTabStrip"

    static func idealWidth(forTabCount count: Int) -> CGFloat {
        CGFloat(max(1, count)) * idealTabWidth + 2 * inset
    }

    let tabs: SessionTabs
    let layout: SessionTabStripLayout
    var onSelect: (UUID) -> Void = { _ in }
    var onClose: (UUID) -> Void = { _ in }
    var onStopRecording: (UUID) -> Void = { _ in }
    /// Passes the actions button's frame in the hosting view's flipped coordinates.
    var onShowActions: (UUID, CGRect) -> Void = { _, _ in }
    @State private var hovered: UUID?

    var body: some View {
        GeometryReader { proxy in
            let count = CGFloat(max(1, tabs.tabs.count))
            let width = max(Self.minimumTabWidth, proxy.size.width / count)
            ScrollViewReader { scroller in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(Array(tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                            SessionTabView(
                                tab: tab,
                                capture: tabs.session(for: tab.id)?.capture,
                                isSelected: tab.id == tabs.selection,
                                isHovered: tab.id == hovered,
                                showsDivider: index > 0 && !isEmphasized(index) && !isEmphasized(index - 1),
                                onSelect: { onSelect(tab.id) },
                                onClose: { onClose(tab.id) },
                                onStopRecording: { onStopRecording(tab.id) },
                                onShowActions: { onShowActions(tab.id, $0) },
                                onHover: { inside in
                                    if inside { hovered = tab.id } else if hovered == tab.id { hovered = nil }
                                }
                            )
                            .frame(width: width, height: proxy.size.height)
                            .id(tab.id)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.coordinateSpace)) } action: {
                                layout.frames[tab.id] = $0
                            }
                            .onDisappear { layout.frames[tab.id] = nil }
                        }
                    }
                }
                .scrollIndicators(.never)
                .scrollDisabled(width * count <= proxy.size.width + 0.5)
                .onChange(of: tabs.selection) { _, selection in
                    guard let selection else { return }
                    withAnimation { scroller.scrollTo(selection) }
                }
            }
        }
        .padding(.horizontal, Self.inset)
        .coordinateSpace(.named(Self.coordinateSpace))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    /// The shown and hovered tabs hide the dividers on both sides.
    private func isEmphasized(_ index: Int) -> Bool {
        let id = tabs.tabs[index].id
        return id == tabs.selection || id == hovered
    }
}

/// Like Safari's compact tabs: the close button shows on the left while the pointer is over the tab,
/// and the shown tab has an actions button on the right. Both sit in the title's padding, so the title
/// stays centered.
private struct SessionTabView: View {
    let tab: SessionTabs.Tab
    /// Read directly, so a hidden tab shows its recording too.
    let capture: SessionCapture?
    let isSelected: Bool
    let isHovered: Bool
    let showsDivider: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onStopRecording: () -> Void
    let onShowActions: (CGRect) -> Void
    let onHover: (Bool) -> Void
    /// Hovering the button reevaluates the body, which refreshes the elapsed time in its help.
    @State private var recordHovered = false
    @State private var actionsFrame = CGRect.zero

    var body: some View {
        HStack(spacing: 6) {
            if let recording {
                recordButton(recording)
            } else if let dotColor {
                Circle()
                    .fill(Color(nsColor: dotColor))
                    .frame(width: 7, height: 7)
            }
            Text(tab.title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: NSFont.systemFontSize))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // A plain raised fill: glass on the toolbar's glass capsule stacks two bright rims.
            if isSelected {
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
            } else if isHovered {
                Capsule().fill(.quaternary)
            }
        }
        .overlay(alignment: .leading) {
            if isHovered {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .frame(width: 16, height: 16)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close Tab")
                .padding(.leading, 6)
            }
        }
        .overlay(alignment: .leading) {
            if showsDivider {
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1, height: 14)
            }
        }
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .help(tab.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onSelect)
        .accessibilityAction(named: "Close Tab", onClose)
        .accessibilityActions {
            if recording == .recording {
                Button("Stop Recording", action: onStopRecording)
            }
        }
        // After the tab's element, so VoiceOver reaches the button on its own.
        .overlay(alignment: .trailing) {
            if isSelected {
                Button { onShowActions(actionsFrame) } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Tab Actions")
                .accessibilityLabel("Tab Actions")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SessionTabStrip.coordinateSpace)) } action: {
                    actionsFrame = $0
                }
                .padding(.trailing, 6)
            }
        }
        .onHover(perform: onHover)
    }

    /// Replaces the status dot: recording needs a connected session, so the dot would always be green.
    private func recordButton(_ recording: Recording) -> some View {
        Button(action: onStopRecording) {
            Image(systemName: "record.circle")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(recording == .finishing)
        .opacity(recording == .finishing ? 0.4 : 1)
        .help(recordingHelp)
        .onHover { recordHovered = $0 }
    }

    private enum Recording { case recording, finishing }

    private var recording: Recording? {
        switch capture?.recordingState {
        case .recording: .recording
        case .finishing: .finishing
        default: nil
        }
    }

    private var recordingHelp: String {
        _ = recordHovered
        guard let elapsed = capture?.recordingState.elapsed() else { return "Finishing Recording" }
        return "Recording for \(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond))). Click to stop."
    }

    private var accessibilityValue: String {
        let status = tab.needsAttention ? "Needs attention" : tab.state.statusTitle
        switch recording {
        case .recording: return "\(status), recording"
        case .finishing: return "\(status), finishing recording"
        case nil: return status
        }
    }

    /// The shown tab shows its session status. A hidden tab shows an orange dot only while a request waits.
    private var dotColor: NSColor? {
        if isSelected { tab.state.statusColor } else if tab.needsAttention { .systemOrange } else { nil }
    }
}

/// Where each tab sits in the strip, in the hosting view's flipped coordinates. The toolbar takes
/// secondary clicks before SwiftUI sees them, so the window controller shows the tab menu from this.
@MainActor
final class SessionTabStripLayout {
    fileprivate var frames: [UUID: CGRect] = [:]

    func tab(at point: CGPoint) -> UUID? {
        frames.first { $0.value.contains(point) }?.key
    }
}
