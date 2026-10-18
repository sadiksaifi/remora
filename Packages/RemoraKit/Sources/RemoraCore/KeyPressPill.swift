import CoreGraphics
import CoreText
import Foundation

/// The key press pill's content, layout and placement, shared by the screen's glass view and the recorder.
/// Only the material differs between them. The capsule follows AgentControlCapsule: semibold system type
/// and controls inset 5 points from the edge. Typed text sits on the glass; keys and shortcuts sit in
/// capsule keycaps, followed by any repeat count.
public struct KeyPressPill: Equatable, Sendable {
    public enum Kind: Sendable { case text, key, count }
    public struct Item: Equatable, Sendable {
        public let text: String
        public let kind: Kind
        /// From the pill's top left, in the pill's units.
        public let frame: CGRect
    }

    /// The user's size choices, as multiples of the standard size.
    public static let sizes: ClosedRange<Double> = 0.75...2
    public let items: [Item]
    public let size: CGSize
    /// Units per point: view points per point on screen, desktop pixels per point in recordings.
    public let scale: CGFloat

    public init?(text: String?, isText: Bool, scale: CGFloat) {
        guard let text else { return nil }
        let height: CGFloat = 44, inset: CGFloat = 5
        let blank = text.allSatisfy(\.isWhitespace)
        let parts = text.components(separatedBy: " ×")
        let keys = isText && !blank ? [] : blank ? ["Space"] : parts[0].split(separator: "+").map(String.init)
        var items: [Item] = []
        var x: CGFloat = 0
        // Measured at the drawn size, because SF Pro's tracking changes with its optical size.
        func add(_ text: String, _ kind: Kind, before: CGFloat, padding: CGFloat, minimum: CGFloat = 0) {
            let width = max(minimum * scale, Self.width(text, kind, scale: scale) + 2 * padding * scale)
            x += before * scale
            items.append(Item(text: text, kind: kind, frame: CGRect(x: x, y: (kind == .key ? inset : 0) * scale,
                width: width, height: (kind == .key ? height - 2 * inset : height) * scale)))
            x += width
        }
        if keys.isEmpty {
            add(text, .text, before: 0, padding: 18)
        } else {
            for key in keys { add(key, .key, before: items.isEmpty ? inset : 4, padding: 12, minimum: height - 2 * inset) }
            if parts.count > 1 { add("×" + parts[1], .count, before: 0, padding: 10) }
            x += (items.last?.kind == .count ? 4 : inset) * scale
        }
        self.items = items
        size = CGSize(width: max(height * scale, x), height: height * scale)
        self.scale = scale
    }

    public static func fontSize(_ kind: Kind) -> CGFloat { kind == .text ? 22 : 16 }

    /// SF Pro Semibold, as SwiftUI's `.system(size:weight: .semibold)`.
    public static func font(_ kind: Kind, scale: CGFloat) -> CTFont {
        let size = fontSize(kind) * scale
        let system = CTFontCreateUIFontForLanguage(.system, size, nil)!
        return CTFontCreateWithFontDescriptor(CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(system),
            [kCTFontTraitsAttribute: [kCTFontWeightTrait: 0.3]] as CFDictionary), size, nil)
    }

    private static func width(_ text: String, _ kind: Kind, scale: CGFloat) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font(kind, scale: scale)]))
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    /// The pill for a snapshot in desktop pixels, and its frame at the bottom center of the desktop.
    /// A point is the session's backing scale, but at least the desktop height over 1080, so large fixed
    /// desktops stay legible. The pill's bottom sits 64 points up, clear of a taskbar or dock.
    public static func placed(_ state: SessionOverlayState.Snapshot, desktop: CGSize) -> (pill: KeyPressPill, frame: CGRect)? {
        let unit = max(CGFloat(state.scale), desktop.height / 1080)
        guard let standard = KeyPressPill(text: state.keyText, isText: state.keyIsText, scale: unit * state.keySize) else { return nil }
        let fit = min(1, max(0.1, (desktop.width - 16 * unit) / standard.size.width))
        let pill = fit < 1 ? KeyPressPill(text: state.keyText, isText: state.keyIsText, scale: standard.scale * fit)! : standard
        return (pill, CGRect(x: ((desktop.width - pill.size.width) / 2).rounded(),
            y: max(0, desktop.height - pill.size.height - 64 * unit).rounded(), width: pill.size.width, height: pill.size.height))
    }
}
