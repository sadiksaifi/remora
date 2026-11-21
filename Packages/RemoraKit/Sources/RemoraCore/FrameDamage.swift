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

    /// Between consecutive edges, merge the covering spans. A span that continues unchanged into the next band
    /// extends its rectangle, so coalescing never adds undamaged pixels and a change elsewhere in the band never
    /// splits it.
    private static func union(_ input: [DirtyRectangle]) -> [DirtyRectangle] {
        let byTop = input.sorted { $0.y < $1.y }
        let edges = Set(input.flatMap { [$0.y, $0.bottom] }).sorted()
        var result: [DirtyRectangle] = []
        var active: [DirtyRectangle] = []
        var next = 0
        var open: [Range<Int>: Int] = [:]  // span to the top of its rectangle
        func close(_ span: Range<Int>, top: Int, at bottom: Int) {
            result.append(DirtyRectangle(x: span.lowerBound, y: top, width: span.count, height: bottom - top))
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
            let current = Set(spans)
            for (span, spanTop) in open where !current.contains(span) {
                close(span, top: spanTop, at: top)
                open[span] = nil
            }
            for span in spans where open[span] == nil { open[span] = top }
        }
        for (span, spanTop) in open { close(span, top: spanTop, at: edges.last ?? 0) }
        return result
    }
}
