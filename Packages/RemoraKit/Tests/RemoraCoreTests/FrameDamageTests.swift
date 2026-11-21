import Testing

@testable import RemoraCore

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func mask(_ rectangles: [DirtyRectangle], width: Int, height: Int) -> [Bool] {
    var covered = [Bool](repeating: false, count: width * height)
    for r in rectangles {
        for y in r.y..<(r.y + r.height) {
            for x in r.x..<(r.x + r.width) { covered[y * width + x] = true }
        }
    }
    return covered
}

private func overlaps(_ a: DirtyRectangle, _ b: DirtyRectangle) -> Bool {
    a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
}

/// Staging slots copy and upload exactly these rectangles, so they must cover the union and nothing else, once.
@Test func damageIsTheExactDisjointUnionOfEveryBatch() {
    let width = 96
    let height = 64
    var random = SplitMix64(state: 21)
    for _ in 0..<200 {
        var damage = FrameDamage()
        var inserted: [DirtyRectangle] = []
        for _ in 0..<Int.random(in: 1...4, using: &random) {
            var batch: [DirtyRectangle] = []
            for _ in 0..<Int.random(in: 1...40, using: &random) {
                // Tile-aligned rectangles, as H.264 regions arrive, mixed with arbitrary ones and repeats.
                let tile = Bool.random(using: &random) ? 16 : 1
                let x = Int.random(in: 0..<(width / tile), using: &random) * tile
                let y = Int.random(in: 0..<(height / tile), using: &random) * tile
                let w = Int.random(in: 1...max(1, (width - x) / tile), using: &random) * tile
                let h = Int.random(in: 1...max(1, (height - y) / tile), using: &random) * tile
                batch.append(DirtyRectangle(x: x, y: y, width: min(w, width - x), height: min(h, height - y)))
                if Int.random(in: 0..<8, using: &random) == 0 { batch.append(batch.last!) }
            }
            damage.insert(contentsOf: batch)
            inserted += batch
        }
        let result = damage.rectangles
        #expect(result.allSatisfy { $0.width > 0 && $0.height > 0 })
        #expect(mask(result, width: width, height: height) == mask(inserted, width: width, height: height))
        for i in result.indices {
            for j in result.indices where j > i { #expect(!overlaps(result[i], result[j])) }
        }
    }
}

/// A full-screen H.264 update arrives as a grid of tiles. It must upload as one blit, not one per tile.
@Test func adjacentTilesCoalesceIntoOneRectangle() {
    var damage = FrameDamage()
    damage.insert(
        contentsOf: stride(from: 0, to: 1088, by: 64).flatMap { y in
            stride(from: 0, to: 1920, by: 64).map { DirtyRectangle(x: $0, y: y, width: 64, height: 64) }
        })
    #expect(damage.rectangles == [DirtyRectangle(x: 0, y: 0, width: 1920, height: 1088)])
}

/// A change in one part of a band must not split damage that continues unchanged elsewhere in it.
@Test func unchangedSpansStayWholeBesideStaggeredDamage() {
    let strips = stride(from: 0, to: 128, by: 8).map { DirtyRectangle(x: $0, y: 0, width: 4, height: 1024) }
    let dots = stride(from: 0, to: 1024, by: 16).map { DirtyRectangle(x: 200, y: $0, width: 4, height: 4) }
    var damage = FrameDamage()
    damage.insert(contentsOf: strips + dots)
    #expect(damage.rectangles.count == strips.count + dots.count)
    #expect(strips.allSatisfy(damage.rectangles.contains))
}
