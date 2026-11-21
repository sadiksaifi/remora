extension DirtyRectangle {
    var right: Int { x + width }
    var bottom: Int { y + height }

    func clipped(width frameWidth: Int, height frameHeight: Int) -> DirtyRectangle? {
        guard width > 0, height > 0, x < frameWidth, y < frameHeight else { return nil }
        let (endX, overflowX) = x.addingReportingOverflow(width)
        let (endY, overflowY) = y.addingReportingOverflow(height)
        let left = max(0, x)
        let top = max(0, y)
        let right = min(frameWidth, overflowX ? Int.max : endX)
        let bottom = min(frameHeight, overflowY ? Int.max : endY)
        guard right > left, bottom > top else { return nil }
        return DirtyRectangle(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// An exact, disjoint union. Never blit the unwritten holes in a reused staging slot.
/// Each batch costs one sweep over horizontal bands, so a frame of many tiles stays cheap.
struct FrameDamage {
    private(set) var rectangles: [DirtyRectangle] = []

    mutating func insert(contentsOf added: some Sequence<DirtyRectangle>) {
        let count = rectangles.count
        rectangles.append(contentsOf: added.lazy.filter { $0.width > 0 && $0.height > 0 })
        if rectangles.count > count { rectangles = Self.union(rectangles) }
    }

    /// Between consecutive edges, merge the covering spans. Join a band to the one above when their spans match,
    /// so coalescing never adds undamaged pixels.
    private static func union(_ input: [DirtyRectangle]) -> [DirtyRectangle] {
        let byTop = input.sorted { $0.y < $1.y }
        let edges = Set(input.flatMap { [$0.y, $0.bottom] }).sorted()
        var result: [DirtyRectangle] = []
        var active: [DirtyRectangle] = []
        var next = 0
        var open: (top: Int, spans: [Range<Int>])?
        func close(at bottom: Int) {
            guard let open else { return }
            for span in open.spans {
                result.append(DirtyRectangle(x: span.lowerBound, y: open.top, width: span.count, height: bottom - open.top))
            }
        }
        for top in edges.dropLast() {
            active.removeAll { $0.bottom <= top }
            while next < byTop.count, byTop[next].y <= top {
                active.append(byTop[next])
                next += 1
            }
            var spans: [Range<Int>] = []
            for span in active.map({ $0.x..<$0.right }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let last = spans.last, span.lowerBound <= last.upperBound {
                    spans[spans.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
                } else {
                    spans.append(span)
                }
            }
            if open?.spans == spans { continue }
            close(at: top)
            open = spans.isEmpty ? nil : (top, spans)
        }
        close(at: edges.last ?? 0)
        return result
    }
}
