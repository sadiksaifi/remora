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
    private nonisolated static let coordinateSpace = "SessionTabStrip"

    static func idealWidth(forTabCount count: Int) -> CGFloat {
        CGFloat(max(1, count)) * idealTabWidth + 2 * inset
    }

    let tabs: SessionTabs
    let layout: SessionTabStripLayout
    var onSelect: (UUID) -> Void = { _ in }
    var onClose: (UUID) -> Void = { _ in }
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
                                isSelected: tab.id == tabs.selection,
                                isHovered: tab.id == hovered,
                                showsDivider: index > 0 && !isEmphasized(index) && !isEmphasized(index - 1),
                                onSelect: { onSelect(tab.id) },
                                onClose: { onClose(tab.id) },
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

private struct SessionTabView: View {
    let tab: SessionTabs.Tab
    let isSelected: Bool
    let isHovered: Bool
    let showsDivider: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let dotColor {
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
        .overlay(alignment: .trailing) {
            if isSelected || isHovered {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close Tab")
                .padding(.trailing, 7)
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
        .onHover(perform: onHover)
        .help(tab.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.title)
        .accessibilityValue(tab.needsAttention ? "Needs attention" : tab.state.statusTitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onSelect)
        .accessibilityAction(named: "Close Tab", onClose)
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
