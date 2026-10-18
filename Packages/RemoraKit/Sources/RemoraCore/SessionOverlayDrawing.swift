import CoreGraphics
import CoreText
import Foundation

/// Shared raster artwork in desktop pixels, with top-left coordinates. Each consumer owns a cache.
/// AppKit and movies both use these exact images and placement.
public final class SessionOverlayDrawing {
    public struct Sprite {
        public let image: CGImage
        public let rect: CGRect
        public let opacity: Double
    }
    private var pill: (text: String, isText: Bool, unit: CGFloat, image: CGImage)?
    private lazy var arrow = Self.image(width: 24, height: 27) { context in
        context.translateBy(x: 4, y: 4)
        let points: [(CGFloat, CGFloat)] = [(0, 0), (0, 15.2), (3.9, 11.5), (6.5, 17.6), (9.2, 16.4), (6.6, 10.5), (12, 10.5)]
        context.addLines(between: points.map { CGPoint(x: $0.0 * 13 / 15, y: $0.1 * 13 / 15) })
        context.closePath()
        context.setShadow(offset: CGSize(width: 0, height: 1), blur: 1.5, color: CGColor(gray: 0, alpha: 0.3))
        context.setFillColor(Self.blue)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(1.5)
        context.setLineJoin(.round)
        context.drawPath(using: .fillStroke)
    }
    private lazy var ring = Self.image(width: 32, height: 32) { context in
        for (inset, width, color): (CGFloat, CGFloat, CGColor) in [
            (1.5, 1, CGColor(gray: 1, alpha: 0.85)), (3, 2, Self.blue), (4.5, 1, CGColor(gray: 1, alpha: 0.6))
        ] {
            context.setStrokeColor(color)
            context.setLineWidth(width)
            context.strokeEllipse(in: CGRect(x: inset, y: inset, width: 32 - inset * 2, height: 32 - inset * 2))
        }
    }
    private static let blue = CGColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)

    public init() {}

    public func sprites(_ state: SessionOverlayState.Snapshot, desktop: CGSize, recording: Bool) -> [Sprite] {
        var result: [Sprite] = []
        let scale = state.scale
        let pointerVisible = recording ? state.showPointerInRecordings : state.showAgentPointer
        if pointerVisible {
            for click in state.clicks where recording || click.source == .agent {
                result.append(Sprite(image: ring,
                    rect: CGRect(x: click.point.x + 0.5 - 16 * scale, y: click.point.y + 0.5 - 16 * scale,
                                 width: 32 * scale, height: 32 * scale),
                    opacity: 0.85 * pow(max(0, 1 - (state.time - click.time) / 0.5), 2)))
            }
            if let point = state.point {
                if state.owner == .agent {
                    result.append(Sprite(image: arrow, rect: CGRect(x: point.x + 0.5 - 4 * scale,
                        y: point.y + 0.5 - 4 * scale, width: 24 * scale, height: 27 * scale), opacity: 1))
                } else if recording, let image = state.cursor {
                    result.append(Sprite(image: image, rect: CGRect(x: point.x - state.hotspot.x,
                        y: point.y - state.hotspot.y, width: CGFloat(image.width), height: CGFloat(image.height)), opacity: 1))
                }
            }
        }
        if let text = state.keyText {
            // Points at the session's scale, but never smaller than at 1080p, so large fixed desktops stay legible.
            let unit = max(CGFloat(scale), desktop.height / 1080)
            if pill?.text != text || pill?.isText != state.keyIsText || pill?.unit != unit {
                pill = (text, state.keyIsText, unit, Self.makePill(text, isText: state.keyIsText, unit: unit))
            }
            if let image = pill?.image {
                let fit = min(1, max(0.1, (desktop.width - 16 * unit) / CGFloat(image.width)))
                let width = CGFloat(image.width) * fit, height = CGFloat(image.height) * fit
                let fade = state.keyOpacity * state.keyOpacity * (3 - 2 * state.keyOpacity)
                // The image's 16-point shadow margin adds to this, so the pill clears a taskbar or dock.
                result.append(Sprite(image: image, rect: CGRect(x: (desktop.width - width) / 2,
                    y: max(0, desktop.height - height - 48 * unit), width: width, height: height), opacity: fade))
            }
        }
        return result
    }

    /// A dark HUD, opaque enough to read over any desktop without a blur, with a hairline edge for dark
    /// desktops and a shadow for light ones. Typed text sits on the pill; keys and shortcuts sit in keycaps
    /// followed by any repeat count. Layout is in points; the image is `unit` pixels per point.
    private static func makePill(_ text: String, isText: Bool, unit: CGFloat) -> CGImage {
        func line(_ string: String, size: CGFloat, weight: CGFloat, gray: CGFloat) -> (line: CTLine, width: CGFloat, cap: CGFloat) {
            let system = CTFontCreateUIFontForLanguage(.system, size, nil)!
            let font = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(system),
                [kCTFontTraitsAttribute: [kCTFontWeightTrait: weight]] as CFDictionary), size, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1)
            ]))
            return (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), CTFontGetCapHeight(font))
        }
        let blank = text.allSatisfy(\.isWhitespace)
        let parts = text.components(separatedBy: " ×")
        let keys = isText && !blank ? [] : (blank ? ["Space"] : parts[0].split(separator: "+").map(String.init))
            .map { line($0, size: 16, weight: 0.3, gray: 1) }
        let label = keys.isEmpty ? line(text, size: 22, weight: 0.23, gray: 1)
            : parts.count > 1 ? line("×" + parts[1], size: 16, weight: 0.23, gray: 0.7) : nil
        let height: CGFloat = 44, margin: CGFloat = 16
        var x = margin, caps: [CGRect] = []
        for key in keys {
            x += caps.isEmpty ? 7 : 5
            caps.append(CGRect(x: x, y: margin + 7, width: max(30, key.width + 20), height: 30))
            x = caps.last!.maxX
        }
        let labelX = x + (keys.isEmpty ? 18 : 10)
        x = label.map { labelX + $0.width + (keys.isEmpty ? 18 : 14) } ?? x + 7
        let body = CGRect(x: margin, y: margin, width: max(height, x - margin), height: height)
        func draw(_ text: (line: CTLine, width: CGFloat, cap: CGFloat), x: CGFloat, in context: CGContext) {
            context.saveGState()
            context.translateBy(x: x, y: body.midY + text.cap / 2)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(text.line, context)
            context.restoreGState()
        }
        return image(width: Int(ceil((body.width + 2 * margin) * unit)), height: Int(ceil((height + 2 * margin) * unit))) { context in
            context.scaleBy(x: unit, y: unit)
            let shape = CGPath(roundedRect: body, cornerWidth: 14, cornerHeight: 14, transform: nil)
            context.saveGState()
            // Shadow geometry is in device pixels and ignores the flip.
            context.setShadow(offset: CGSize(width: 0, height: -4 * unit), blur: 16 * unit, color: CGColor(gray: 0, alpha: 0.35))
            context.setFillColor(CGColor(gray: 0.1, alpha: 0.82))
            context.addPath(shape)
            context.fillPath()
            context.restoreGState()
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
            context.addPath(CGPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 13.5, cornerHeight: 13.5, transform: nil))
            context.strokePath()
            context.setFillColor(CGColor(gray: 1, alpha: 0.16))
            for (key, cap) in zip(keys, caps) {
                context.addPath(CGPath(roundedRect: cap, cornerWidth: 7, cornerHeight: 7, transform: nil))
                context.fillPath()
                draw(key, x: cap.midX - key.width / 2, in: context)
            }
            if let label { draw(label, x: labelX, in: context) }
        }
    }

    private static func image(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(context)
        return context.makeImage()!
    }
}
