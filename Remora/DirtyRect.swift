/// A rectangle in the remote framebuffer's top-left pixel coordinate system.
struct DirtyRect: Sendable, Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    fileprivate var right: Int { x + width }
    fileprivate var bottom: Int { y + height }

    func clipped(width frameWidth: Int, height frameHeight: Int) -> DirtyRect? {
        guard width > 0, height > 0, x < frameWidth, y < frameHeight else { return nil }
        let (endX, overflowX) = x.addingReportingOverflow(width)
        let (endY, overflowY) = y.addingReportingOverflow(height)
        let left = max(0, x)
        let top = max(0, y)
        let right = min(frameWidth, overflowX ? Int.max : endX)
        let bottom = min(frameHeight, overflowY ? Int.max : endY)
        guard right > left, bottom > top else { return nil }
        return DirtyRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
