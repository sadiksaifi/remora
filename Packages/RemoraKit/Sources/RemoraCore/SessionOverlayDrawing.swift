import CoreGraphics
import CoreText
import Foundation

/// Shared raster artwork in desktop pixels, with top-left coordinates. Each consumer owns a cache.
/// AppKit and movies both use these exact pointer images and placement. The screen draws the key press
/// pill as Liquid Glass; movies draw `keyPress(_:desktop:)` over a blurred backdrop.
public final class SessionOverlayDrawing {
    public struct Sprite {
        public let image: CGImage
        public let rect: CGRect
        public let opacity: Double
    }
    /// The recorder's key press glass: the capsule's frame, and its shadow, rim, keycaps and text
    /// in `image` over `imageRect`. The compositor blurs and tints the desktop inside the capsule.
    public struct Glass {
        public let frame: CGRect
        public let image: CGImage
        public let imageRect: CGRect
        public let opacity: Double
        public let dark: Bool
    }
    private var glass: (pill: KeyPressPill, dark: Bool, image: CGImage)?
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
        return result
    }

    public func keyPress(_ state: SessionOverlayState.Snapshot, desktop: CGSize) -> Glass? {
        guard let (pill, frame) = KeyPressPill.placed(state, desktop: desktop) else { return nil }
        if glass?.pill != pill || glass?.dark != state.dark { glass = (pill, state.dark, Self.makeGlass(pill, dark: state.dark)) }
        let margin = 16 * pill.scale
        return Glass(frame: frame, image: glass!.image, imageRect: frame.insetBy(dx: -margin, dy: -margin),
            opacity: state.keyOpacity * state.keyOpacity * (3 - 2 * state.keyOpacity), dark: state.dark)
    }

    /// Label colors as AppKit resolves them for the appearance, and a hairline rim brighter at the top.
    private static func makeGlass(_ pill: KeyPressPill, dark: Bool) -> CGImage {
        let scale = pill.scale, margin = 16 * scale
        let body = CGRect(origin: CGPoint(x: margin, y: margin), size: pill.size)
        let shape = CGPath(roundedRect: body, cornerWidth: body.height / 2, cornerHeight: body.height / 2, transform: nil)
        let label = CGFloat(dark ? 1 : 0)
        return image(width: Int(ceil(body.width + 2 * margin)), height: Int(ceil(body.height + 2 * margin))) { context in
            context.saveGState()
            // Shadow geometry is in device pixels and ignores the flip. The glass covers the capsule itself.
            context.setShadow(offset: CGSize(width: 0, height: -2 * scale), blur: 12 * scale, color: CGColor(gray: 0, alpha: 0.22))
            context.addPath(shape)
            context.fillPath()
            context.restoreGState()
            context.setBlendMode(.clear)
            context.addPath(shape)
            context.fillPath()
            context.setBlendMode(.normal)
            context.saveGState()
            context.addPath(CGPath(roundedRect: body.insetBy(dx: 0.5 * scale, dy: 0.5 * scale),
                cornerWidth: body.height / 2 - 0.5 * scale, cornerHeight: body.height / 2 - 0.5 * scale, transform: nil))
            context.setLineWidth(scale)
            context.replacePathWithStrokedPath()
            context.clip()
            let rim = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
                CGColor(gray: 1, alpha: dark ? 0.22 : 0.9), CGColor(gray: 1, alpha: dark ? 0.04 : 0.3),
                CGColor(gray: 1, alpha: dark ? 0.1 : 0.6)] as CFArray, locations: [0, 0.5, 1])!
            context.drawLinearGradient(rim, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
            context.restoreGState()
            for item in pill.items {
                let frame = item.frame.offsetBy(dx: margin, dy: margin)
                if item.kind == .key {
                    context.setFillColor(CGColor(gray: label, alpha: dark ? 0.08 : 0.07))
                    context.addPath(CGPath(roundedRect: frame, cornerWidth: frame.height / 2, cornerHeight: frame.height / 2, transform: nil))
                    context.fillPath()
                }
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: item.text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): KeyPressPill.font(item.kind, scale: scale),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                        CGColor(gray: label, alpha: item.kind == .count ? 0.5 : 0.85)
                ]))
                var ascent: CGFloat = 0, descent: CGFloat = 0
                let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
                // SwiftUI centers the line box, so the baseline sits half the ascent and descent difference below the middle.
                context.saveGState()
                context.translateBy(x: frame.midX - width / 2, y: frame.midY + (ascent - descent) / 2)
                context.scaleBy(x: 1, y: -1)
                context.textPosition = .zero
                CTLineDraw(line, context)
                context.restoreGState()
            }
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
