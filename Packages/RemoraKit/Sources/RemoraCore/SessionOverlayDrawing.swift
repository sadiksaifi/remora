import CoreGraphics
import CoreText
import Foundation

/// Shared raster artwork in desktop pixels, with top-left coordinates. Each consumer owns a cache.
/// Restyle the pill in makePill; AppKit and movies both use these exact images and placement.
public final class SessionOverlayDrawing {
    public struct Sprite {
        public let image: CGImage
        public let rect: CGRect
        public let opacity: Double
    }
    private var pill: (text: String, image: CGImage)?
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
            if pill?.text != text { pill = (text, Self.makePill(text)) }
            if let image = pill?.image {
                let fit = min(scale, max(0.1, (desktop.width - 24 * scale) / CGFloat(image.width)))
                let width = CGFloat(image.width) * fit, height = CGFloat(image.height) * fit
                result.append(Sprite(image: image, rect: CGRect(x: (desktop.width - width) / 2,
                    y: max(0, desktop.height - height - 24 * scale), width: width, height: height), opacity: state.keyOpacity))
            }
        }
        return result
    }

    private static func makePill(_ text: String) -> CGImage {
        let font = CTFontCreateUIFontForLanguage(.system, 18, nil)!
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ]))
        let width = Int(ceil(CTLineGetTypographicBounds(line, nil, nil, nil))) + 32
        return image(width: max(40, width), height: 40) { context in
            context.setFillColor(CGColor(gray: 0.08, alpha: 0.9))
            context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: max(40, width), height: 40),
                                   cornerWidth: 12, cornerHeight: 12, transform: nil))
            context.fillPath()
            context.translateBy(x: 16, y: 26)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line, context)
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
