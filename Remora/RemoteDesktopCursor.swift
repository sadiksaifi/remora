import AppKit
import RemoraCore

@MainActor
extension RemoteCursor {
    func cursor(pointsPerPixel scale: CGFloat) -> NSCursor {
        switch self {
        case .systemDefault: return .arrow
        case .hidden:
            return RemoteCursor.image(
                pixels: Data(repeating: 0, count: 4), width: 1, height: 1,
                hotspot: RemotePoint(x: 0, y: 0)
            ).cursor(pointsPerPixel: 1)
        case .image(let pixels, let width, let height, let hotspot):
            guard width > 0, height > 0, width <= 384, height <= 384,
                pixels.count == width * height * 4, scale > 0,
                let provider = CGDataProvider(data: pixels as CFData),
                let image = CGImage(
                    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue)],
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
                )
            else { return .arrow }
            let size = NSSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
            return NSCursor(
                image: NSImage(cgImage: image, size: size),
                hotSpot: NSPoint(
                    x: min(CGFloat(hotspot.x), CGFloat(width - 1)) * scale,
                    y: min(CGFloat(hotspot.y), CGFloat(height - 1)) * scale
                ))
        }
    }
}
