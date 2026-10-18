import Foundation

public struct ScreenshotRegion: Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Metadata for the exact crop and encoded dimensions of one framebuffer readback.
public struct ScreenshotGeometry: Sendable, Equatable {
    public let desktop: DesktopSize
    public let region: ScreenshotRegion
    public let encoded: DesktopSize

    public init(desktop: DesktopSize, region: ScreenshotRegion? = nil, maxSize: DesktopSize? = nil) throws {
        let region = region ?? ScreenshotRegion(x: 0, y: 0, width: desktop.width, height: desktop.height)
        guard desktop.width > 0, desktop.height > 0, region.x >= 0, region.y >= 0,
              region.width > 0, region.height > 0, region.width <= desktop.width, region.height <= desktop.height,
              region.x <= desktop.width - region.width, region.y <= desktop.height - region.height else {
            throw CaptureFailure.image("The region must fit within the remote desktop.")
        }
        if let maxSize, maxSize.width <= 0 || maxSize.height <= 0 {
            throw CaptureFailure.image("The maximum size must have positive dimensions.")
        }
        let scale = maxSize.map { min(1, Double($0.width) / Double(region.width), Double($0.height) / Double(region.height)) } ?? 1
        self.desktop = desktop
        self.region = region
        encoded = DesktopSize(width: max(1, Int((Double(region.width) * scale).rounded(.down))),
                              height: max(1, Int((Double(region.height) * scale).rounded(.down))))
    }

    public func remotePoint(x: Int, y: Int) throws -> (x: Int, y: Int) {
        guard x >= 0, y >= 0, x < encoded.width, y < encoded.height else {
            throw CaptureFailure.image("The point must fit within the screenshot.")
        }
        return (Int(floor(Double(region.x) + (Double(x) + 0.5) * Double(region.width) / Double(encoded.width))),
                Int(floor(Double(region.y) + (Double(y) + 0.5) * Double(region.height) / Double(encoded.height))))
    }
}

public struct ScreenshotReceipt: Sendable {
    public let id: UUID
    public let session: UUID
    public let geometry: ScreenshotGeometry
    public let frame: Int
    public let geometryRevision: Int

    public init(id: UUID = UUID(), session: UUID, geometry: ScreenshotGeometry, frame: Int, geometryRevision: Int = 0) {
        self.id = id; self.session = session; self.geometry = geometry; self.frame = frame; self.geometryRevision = geometryRevision
    }
}
