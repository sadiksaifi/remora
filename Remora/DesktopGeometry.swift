import CoreGraphics

/// The same aspect-fit transform drives the Metal viewport and pointer mapping.
struct DesktopGeometry {
    let remoteSize: CGSize
    let contentRect: CGRect

    init(remoteSize: CGSize, drawableSize: CGSize) {
        self.remoteSize = remoteSize
        guard remoteSize.width > 0, remoteSize.height > 0 else {
            contentRect = .zero
            return
        }
        let scale = min(drawableSize.width / remoteSize.width, drawableSize.height / remoteSize.height)
        let size = CGSize(width: remoteSize.width * scale, height: remoteSize.height * scale)
        contentRect = CGRect(
            x: (drawableSize.width - size.width) / 2,
            y: (drawableSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    var isPixelExact: Bool { contentRect.size == remoteSize }

    func remotePoint(for point: CGPoint) -> CGPoint? {
        guard contentRect.width > 0, contentRect.height > 0,
              point.x >= contentRect.minX, point.x < contentRect.maxX,
              point.y >= contentRect.minY, point.y < contentRect.maxY else { return nil }
        return CGPoint(
            x: (point.x - contentRect.minX) * remoteSize.width / contentRect.width,
            y: (point.y - contentRect.minY) * remoteSize.height / contentRect.height
        )
    }
}
