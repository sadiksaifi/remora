import CoreGraphics
import Foundation
import ImageIO
import RemoraCore
import Testing

private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

@Test func cursorPlacementSurvivesSettingsGeometryAndPause() throws {
    let state = SessionOverlayState()
    state.setDesktopSize(CGSize(width: 1920, height: 1080))
    state.receive(.human, .pointer(.init(x: 300, y: 200), []))
    state.setAgentCursorVisible(true)
    #expect(try distance(#require(state.snapshot().agentCursor).pose.hotspot, CGPoint(x: 300, y: 200)) < 0.000001)
    state.moveAgentCursor(to: CGPoint(x: 800, y: 500), animated: false)
    state.configure(showPointerInRecordings: true, showKeyPresses: false, showAgentPointer: false, scale: 2)
    var frame = try #require(state.snapshot().agentCursor)
    #expect(frame.unit == 2)
    #expect(distance(frame.pose.hotspot, CGPoint(x: 800, y: 500)) < 0.000001)
    state.setDesktopSize(CGSize(width: 3840, height: 3240))
    frame = try #require(state.snapshot().agentCursor)
    #expect(frame.unit == 3)
    #expect(distance(frame.pose.hotspot, CGPoint(x: 800, y: 500)) < 0.000001)
    state.setAgentCursorVisible(false)
    state.setAgentCursorVisible(true)
    #expect(try distance(#require(state.snapshot().agentCursor).pose.hotspot, CGPoint(x: 800, y: 500)) < 0.000001)
    state.reset()
    #expect(state.snapshot().agentCursor == nil)
}

/// Opt-in acceptance artifacts use the actual recorder sprite, without launching the app.
@Test func cursorReferenceArtwork() throws {
    guard let folder = ProcessInfo.processInfo.environment["REMORA_CURSOR_ARTIFACTS"] else { return }
    let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let from = CGPoint(x: 116, y: 766)
    let to = CGPoint(x: 781, y: 266)
    let drawing = SessionOverlayDrawing()
    func context(_ width: Int, _ height: Int) throws -> CGContext {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.106, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        return context
    }
    func draw(_ pose: CursorPose, unit: Double, in context: CGContext) {
        let sprite = drawing.agentCursor(AgentCursorFrame(pose: pose, unit: unit))
        context.saveGState()
        context.setAlpha(sprite.opacity)
        context.translateBy(x: sprite.rect.minX, y: sprite.rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(sprite.image, in: CGRect(origin: .zero, size: sprite.rect.size))
        context.restoreGState()
    }
    func write(_ context: CGContext, _ name: String) throws {
        let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }
    var rest = CursorMotion(hotspot: .zero, bounds: bounds)
    let tip = rest.restTipOffset
    rest.place(at: CGPoint(x: 40 + tip.x, y: 40 + tip.y))
    rest.isVisible = true
    rest.step(2)
    let zoom = try context(640, 640)
    draw(rest.pose, unit: 8, in: zoom)
    try write(zoom, "recorder-rest-pose-8x.png")

    let trail = try context(1800, 1280)
    trail.translateBy(x: -120, y: -440)
    var moving = CursorMotion(hotspot: from, bounds: bounds)
    moving.isVisible = true
    moving.step(1)
    moving.move(to: to)
    for frame in 0..<60 {
        draw(moving.pose, unit: 2, in: trail)
        if frame == 0 || moving.isMoving { moving.step(1.0 / 60) } else { break }
    }
    try write(trail, "recorder-move-a-long-exposure.png")
}
