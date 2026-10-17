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

/// An exact, disjoint union. Never blit the unwritten holes in a reused staging slot.
struct FrameDamage {
    private(set) var rectangles: [DirtyRect] = []

    mutating func insert(_ rectangle: DirtyRect) {
        if rectangles.allSatisfy({ rectangle.x <= $0.x && rectangle.y <= $0.y && rectangle.right >= $0.right && rectangle.bottom >= $0.bottom }) {
            rectangles = [rectangle]
            return
        }
        var additions = [rectangle]
        for existing in rectangles {
            additions = additions.flatMap { Self.subtract(existing, from: $0) }
            if additions.isEmpty { return }
        }
        rectangles.append(contentsOf: additions)
        // Merge only rectangular unions, so coalescing never adds undamaged pixels.
        var index = 0
        while index < rectangles.count {
            var other = index + 1
            while other < rectangles.count {
                let a = rectangles[index]
                let b = rectangles[other]
                if a.x == b.x, a.width == b.width, a.bottom == b.y || b.bottom == a.y {
                    rectangles[index] = DirtyRect(x: a.x, y: min(a.y, b.y), width: a.width, height: a.height + b.height)
                } else if a.y == b.y, a.height == b.height, a.right == b.x || b.right == a.x {
                    rectangles[index] = DirtyRect(x: min(a.x, b.x), y: a.y, width: a.width + b.width, height: a.height)
                } else {
                    other += 1
                    continue
                }
                rectangles.remove(at: other)
                index = 0
                other = 1
            }
            index += 1
        }
    }

    private static func subtract(_ b: DirtyRect, from a: DirtyRect) -> [DirtyRect] {
        let left = max(a.x, b.x)
        let top = max(a.y, b.y)
        let right = min(a.right, b.right)
        let bottom = min(a.bottom, b.bottom)
        guard left < right, top < bottom else { return [a] }
        return [
            DirtyRect(x: a.x, y: a.y, width: a.width, height: top - a.y),
            DirtyRect(x: a.x, y: bottom, width: a.width, height: a.bottom - bottom),
            DirtyRect(x: a.x, y: top, width: left - a.x, height: bottom - top),
            DirtyRect(x: right, y: top, width: a.right - right, height: bottom - top),
        ].filter { $0.width > 0 && $0.height > 0 }
    }
}
