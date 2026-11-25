import RemoraCore
import SwiftUI

/// The session tabs at the leading end of the toolbar, drawn like Safari's compact tabs: a flat track with
/// no glass, and the shown tab on a Liquid Glass pill. A lone shown tab is its pill alone, without the track.
/// The window controller limits the strip's width to `idealWidth(forTabCount:restingAsIcons:)`.
/// Tabs share the width. When titles no longer fit, resting tabs show only their icon, and past that the strip scrolls.
/// In a compact toolbar the resting tabs beside the shown tab show only their icon from the start.
struct SessionTabStrip: View {
    static let idealTabWidth: CGFloat = 220
    static let minimumTabWidth: CGFloat = 76
    static let selectedMinimumTabWidth: CGFloat = 132
    /// A resting tab that shows only its icon, and the shown tab once every resting tab is that narrow.
    static let iconTabWidth: CGFloat = 36
    static let selectedTabWidthAmongIcons: CGFloat = 120
    /// The track's height, which is the height of the toolbar's own buttons.
    static let height: CGFloat = 36
    /// The gap between the track and the tabs on every side, so a tab's round end is concentric with the track's.
    static let trackInset: CGFloat = 2
    private static let fadeWidth: CGFloat = 24
    fileprivate nonisolated static let coordinateSpace = "SessionTabStrip"

    static func idealWidth(forTabCount count: Int, restingAsIcons: Bool) -> CGFloat {
        let tabs = restingAsIcons ? idealTabWidth + CGFloat(max(0, count - 1)) * iconTabWidth : CGFloat(max(1, count)) * idealTabWidth
        return tabs + 2 * trackInset
    }

    /// The shown tab between icon-only tabs, with one of them visible beside it.
    static let minimumWidth = selectedTabWidthAmongIcons + iconTabWidth + 2 * trackInset

    let tabs: SessionTabs
    let layout: SessionTabStripLayout
    /// True in a narrow window, where the resting tabs leave the width to the shown tab.
    var isCompact = false
    /// False for a lone shown tab.
    var showsTrack = true
    var onSelect: (UUID) -> Void = { _ in }
    var onClose: (UUID) -> Void = { _ in }
    var onStopRecording: (UUID) -> Void = { _ in }
    var onShowMenu: (UUID) -> Void = { _ in }
    @State private var hovered: UUID?
    @State private var clipped = ClippedEdges()

    var body: some View {
        GeometryReader { proxy in
            let widths = TabWidths(
                available: proxy.size.width - 2 * Self.trackInset, count: tabs.tabs.count,
                hasSelection: tabs.tabs.contains { $0.id == tabs.selection }, isCompact: isCompact)
            ScrollViewReader { scroller in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(Array(tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                            let isSelected = tab.id == tabs.selection
                            let width = isSelected ? widths.selected : widths.resting
                            SessionTabView(
                                tab: tab,
                                capture: tabs.session(for: tab.id)?.capture,
                                isSelected: isSelected,
                                isHovered: tab.id == hovered,
                                showsDivider: index > 0 && !isEmphasized(index) && !isEmphasized(index - 1),
                                width: width,
                                onSelect: { onSelect(tab.id) },
                                onClose: { onClose(tab.id) },
                                onStopRecording: { onStopRecording(tab.id) },
                                onShowMenu: { onShowMenu(tab.id) },
                                onHover: { inside in
                                    if inside { hovered = tab.id } else if hovered == tab.id { hovered = nil }
                                }
                            )
                            .frame(width: width, height: proxy.size.height - 2 * Self.trackInset)
                            .id(tab.id)
                            .onGeometryChange(for: CGRect.self) {
                                $0.frame(in: .named(Self.coordinateSpace))
                            } action: {
                                layout.frames[tab.id] = $0
                            }
                            .onDisappear { layout.frames[tab.id] = nil }
                        }
                    }
                    .padding(Self.trackInset)
                }
                .scrollIndicators(.never)
                .scrollDisabled(widths.total(count: tabs.tabs.count) + 2 * Self.trackInset <= proxy.size.width + 0.5)
                .onScrollGeometryChange(for: ClippedEdges.self) { geometry in
                    ClippedEdges(
                        leading: geometry.contentOffset.x > 0.5,
                        trailing: geometry.contentOffset.x + geometry.containerSize.width < geometry.contentSize.width - 0.5)
                } action: { _, edges in
                    clipped = edges
                }
                .onChange(of: tabs.selection) { _, selection in
                    guard let selection else { return }
                    withAnimation { scroller.scrollTo(selection) }
                }
                // A narrower strip may start to scroll, and the shown tab stays in view.
                .onChange(of: proxy.size.width) {
                    if let selection = tabs.selection { scroller.scrollTo(selection) }
                }
            }
        }
        // Tabs that scroll out fade at the edge they leave by, so a cut-off tab reads as more tabs.
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: clipped.leading ? Self.fadeWidth : 0)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: clipped.trailing ? Self.fadeWidth : 0)
            }
        }
        .background { if showsTrack { Capsule().fill(.fill.tertiary) } }
        .coordinateSpace(.named(Self.coordinateSpace))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    /// The shown and hovered tabs hide the dividers on both sides.
    private func isEmphasized(_ index: Int) -> Bool {
        let id = tabs.tabs[index].id
        return id == tabs.selection || id == hovered
    }

    private struct ClippedEdges: Equatable {
        var leading = false
        var trailing = false
    }
}

/// How wide the shown tab and each resting tab are in a strip of a given width.
/// Tabs are equal while each has `selectedMinimumTabWidth`. Below that the shown tab keeps that width and the
/// resting tabs share the rest, down to `iconTabWidth`. Then the shown tab gives way, down to `selectedTabWidthAmongIcons`.
/// A compact strip starts at that last step: icon-wide resting tabs, and the rest for the shown tab.
@MainActor
struct TabWidths {
    let selected: CGFloat
    let resting: CGFloat

    init(available: CGFloat, count: Int, hasSelection: Bool, isCompact: Bool) {
        let count = CGFloat(max(1, count))
        let equal = available / count
        if !hasSelection {
            selected = 0
            resting = max(SessionTabStrip.iconTabWidth, equal)
        } else if isCompact, count > 1 {
            resting = SessionTabStrip.iconTabWidth
            selected = max(SessionTabStrip.selectedTabWidthAmongIcons, available - SessionTabStrip.iconTabWidth * (count - 1))
        } else if count == 1 || equal >= SessionTabStrip.selectedMinimumTabWidth {
            selected = max(SessionTabStrip.selectedTabWidthAmongIcons, equal)
            resting = equal
        } else {
            let shared = (available - SessionTabStrip.selectedMinimumTabWidth) / (count - 1)
            resting = max(SessionTabStrip.iconTabWidth, shared)
            selected =
                shared >= SessionTabStrip.iconTabWidth
                ? SessionTabStrip.selectedMinimumTabWidth
                : max(SessionTabStrip.selectedTabWidthAmongIcons, available - SessionTabStrip.iconTabWidth * (count - 1))
        }
    }

    func total(count: Int) -> CGFloat {
        selected > 0 ? selected + resting * CGFloat(count - 1) : resting * CGFloat(count)
    }
}

/// One tab: its status icon, its title centered in the space that remains, and a close button on the shown tab
/// and on the tab under the pointer. A tab that shows only its icon has no close button.
private struct SessionTabView: View {
    let tab: SessionTabs.Tab
    /// Read directly, so a hidden tab shows its recording too.
    let capture: SessionCapture?
    let isSelected: Bool
    let isHovered: Bool
    let showsDivider: Bool
    let width: CGFloat
    let onSelect: () -> Void
    let onClose: () -> Void
    let onStopRecording: () -> Void
    let onShowMenu: () -> Void
    let onHover: (Bool) -> Void
    @State private var closeHovered = false

    var body: some View {
        Group {
            if isSelected || isHovered || !showsTitle {
                content(hasCloseButton: showsTitle)
            } else {
                // A resting tab keeps the close button's place free while its whole title fits beside it, so
                // the title stays put when the pointer arrives. A longer title takes that place.
                ViewThatFits(in: .horizontal) {
                    content(hasCloseButton: true)
                    content(hasCloseButton: false)
                }
            }
        }
        .font(.system(size: NSFont.systemFontSize))
        // A resting tab reads like the shown one. Only the glass tells them apart.
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { if isHovered && !isSelected { Capsule().fill(.fill.tertiary) } }
        .glassEffect(isSelected ? .regular : .identity, in: .capsule)
        .overlay(alignment: .leading) {
            if showsDivider {
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1, height: 16)
            }
        }
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onSelect)
        .accessibilityIdentifier("tab-\(tab.id.uuidString)")
        // VoiceOver's route to the menu that a secondary click opens.
        .accessibilityAction(.showMenu, onShowMenu)
        .accessibilityAction(named: "Close Tab", onClose)
        .accessibilityActions {
            if recording == .recording {
                Button("Stop Recording", action: onStopRecording)
            }
        }
        .onHover(perform: onHover)
    }

    private var showsTitle: Bool { isSelected || width >= SessionTabStrip.minimumTabWidth }

    private func content(hasCloseButton: Bool) -> some View {
        HStack(spacing: 6) {
            SessionIndicatorIcon(indicator: tab.indicator(recording: recording))
            if showsTitle {
                Text(tab.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                if hasCloseButton { closeButton }
            }
        }
        .padding(.leading, showsTitle ? (hasCloseButton ? 12 : 10) : 0)
        .padding(.trailing, showsTitle ? (hasCloseButton ? 6 : 10) : 0)
    }

    /// A bare cross. It takes a round fill only while the pointer is over it.
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 20, height: 20)
                .background { if closeHovered { Circle().fill(.quaternary) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { closeHovered = $0 }
        .help("Close Tab")
        .opacity(isSelected || isHovered ? 1 : 0)
        .allowsHitTesting(isSelected || isHovered)
        .accessibilityHidden(true)
    }

    private var recording: SessionTabs.Tab.Recording? {
        switch capture?.recordingState {
        case .recording: .recording
        case .finishing: .finishing
        default: nil
        }
    }

    /// The title, then every state the one icon cannot show together.
    private var help: String {
        let title = tab.display.map { "\(tab.title) – \($0)" } ?? tab.title
        var states = tab.state == .connected && !tab.needsAttention ? [] : [connectionStatus]
        states += otherStates
        return states.isEmpty ? title : "\(title)\n\(states.joined(separator: ", "))"
    }

    private var accessibilityValue: String {
        ([connectionStatus, tab.display].compactMap { $0 } + otherStates).joined(separator: ", ")
    }

    private var connectionStatus: String { tab.needsAttention ? "Needs attention" : tab.state.statusTitle }

    private var otherStates: [String] {
        var states: [String] = []
        if let agent = tab.control.agentStatus(tab.agentName) { states.append(agent.trimmingCharacters(in: ["."])) }
        switch recording {
        case .recording: states.append("recording")
        case .finishing: states.append("finishing recording")
        case nil: break
        }
        return states
    }
}

extension SessionTabs.Tab {
    enum Recording { case recording, finishing }

    /// The tab's one status, also shown in its connection's row.
    func indicator(recording: Recording?) -> SessionIndicator {
        SessionIndicator(state: state, hasWaitingRequest: needsAttention, control: control, isRecording: recording != nil)
    }
}

/// A session's one status as a 14 pt icon. Connecting shows the stock spinner.
struct SessionIndicatorIcon: View {
    let indicator: SessionIndicator

    var body: some View {
        Group {
            if let symbol = indicator.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: indicator.tint))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

extension SessionIndicator {
    /// Nil while connecting, which shows a spinner.
    var symbolName: String? {
        switch self {
        case .needsAttention: "exclamationmark.circle.fill"
        case .connecting: nil
        case .disconnected: "network.slash"
        case .agentInControl: "pointer.arrow.motionlines"
        case .recording: "record.circle"
        case .agentPaused: "pointer.arrow.slash"
        case .none: "display"
        }
    }

    var tint: NSColor {
        switch self {
        case .needsAttention: .systemOrange
        case .agentInControl: .systemBlue
        case .recording: .systemRed
        case .connecting, .disconnected, .agentPaused, .none: .secondaryLabelColor
        }
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

    func frame(of tab: UUID) -> CGRect? { frames[tab] }
}
