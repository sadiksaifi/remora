import Foundation
import Testing

@testable import RemoraCore

@Test func screenshotCoordinatesUseEncodedPixelCenters() throws {
    let geometry = try ScreenshotGeometry(
        desktop: .init(width: 1920, height: 1080),
        region: .init(x: 101, y: 53, width: 1001, height: 601), maxSize: .init(width: 333, height: 300))
    #expect(geometry.encoded == DesktopSize(width: 333, height: 199))
    let first = try geometry.remotePoint(x: 0, y: 0)
    #expect(first.x == 102 && first.y == 54)
    let last = try geometry.remotePoint(x: 332, y: 198)
    #expect(last.x == 1100 && last.y == 652)
    #expect(throws: CaptureFailure.self) { try geometry.remotePoint(x: 333, y: 0) }
    #expect(throws: CaptureFailure.self) { try geometry.remotePoint(x: -1, y: 0) }
}

@Test func screenshotRegionsRejectOutOfBoundsAndNeverUpscale() throws {
    let desktop = DesktopSize(width: 800, height: 600)
    #expect(try ScreenshotGeometry(desktop: desktop, maxSize: .init(width: 1600, height: 1200)).encoded == desktop)
    for region in [
        ScreenshotRegion(x: -1, y: 0, width: 2, height: 2),
        .init(x: 799, y: 0, width: 2, height: 2), .init(x: 0, y: 0, width: 0, height: 2),
        .init(x: Int.max, y: 0, width: Int.max, height: 2),
    ] {
        #expect(throws: CaptureFailure.self) { try ScreenshotGeometry(desktop: desktop, region: region) }
    }
}
