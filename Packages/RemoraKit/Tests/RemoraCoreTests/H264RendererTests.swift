import CFreeRDPReference
import CoreVideo
import Metal
import Synchronization
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

/// An IOSurface-backed three-plane I420 picture, as VideoToolbox decodes one, filled with random samples.
private func picture(width: Int, height: Int, using random: inout SplitMix64) throws -> CVPixelBuffer {
    var image: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
    let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8Planar, attributes as CFDictionary, &image)
    let created = try #require(image)
    #expect(status == kCVReturnSuccess)
    CVPixelBufferLockBaseAddress(created, [])
    defer { CVPixelBufferUnlockBaseAddress(created, []) }
    for plane in 0..<3 {
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(created, plane)).assumingMemoryBound(to: UInt8.self)
        let count = CVPixelBufferGetBytesPerRowOfPlane(created, plane) * CVPixelBufferGetHeightOfPlane(created, plane)
        for index in 0..<count { base[index] = UInt8.random(in: 0...255, using: &random) }
    }
    return created
}

private func rectangles(width: Int, height: Int, using random: inout SplitMix64) -> [H264Renderer.Rectangle] {
    (0..<Int.random(in: 1...6, using: &random)).map { _ in
        let left = Int.random(in: 0..<width, using: &random)
        let top = Int.random(in: 0..<height, using: &random)
        return .init(
            left: left, top: top, right: Int.random(in: (left + 1)...width, using: &random),
            bottom: Int.random(in: (top + 1)...height, using: &random))
    }
}

/// Runs FreeRDP's CPU conversion and the GPU conversion over the same pictures, and compares every drawn pixel.
private struct Comparison {
    let width, height: Int
    let target: H264Renderer.Target
    let renderer: H264Renderer
    let reference: OpaquePointer
    var expected: [UInt8]
    var drawn: [Bool]

    /// The surface lands on the desktop at the origin; the desktop clips it on the right and bottom.
    init(width: Int, height: Int, lumaStride: Int, originX: Int = 0, originY: Int = 0, desktopWidth: Int? = nil, desktopHeight: Int? = nil) throws {
        self.width = width
        self.height = height
        let desktopWidth = desktopWidth ?? width
        let desktopHeight = desktopHeight ?? height
        target = H264Renderer.Target(
            surface: 1, surfaceWidth: width, surfaceHeight: height, originX: originX, originY: originY,
            visibleWidth: min(width, desktopWidth - originX), visibleHeight: min(height, desktopHeight - originY),
            desktopWidth: desktopWidth, desktopHeight: desktopHeight)
        let device = try #require(MTLCreateSystemDefaultDevice())
        renderer = try H264Renderer(desktop: MetalDesktop(device: device))
        reference = try #require(rm_reference_new(UInt32(width), UInt32(height), UInt32(lumaStride)))
        // One spare column takes the pixel FreeRDP writes right of an odd-width rectangle at the surface's right edge.
        expected = [UInt8](repeating: 0, count: (width + 1) * height * 4)
        drawn = [Bool](repeating: false, count: width * height)
    }

    mutating func draw(_ passes: [H264Renderer.Pass]) throws {
        for pass in passes {
            let layout: Int32 =
                switch pass.layout {
                case .yuv420: 0
                case .luma: 1
                case .chromaV1: 2
                case .chromaV2: 3
                }
            CVPixelBufferLockBaseAddress(pass.image, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pass.image, .readOnly) }
            let planes: [UnsafePointer<UInt8>?] = (0..<3).map {
                CVPixelBufferGetBaseAddressOfPlane(pass.image, $0).map { UnsafePointer($0.assumingMemoryBound(to: UInt8.self)) }
            }
            let strides = (0..<3).map { UInt32(CVPixelBufferGetBytesPerRowOfPlane(pass.image, $0)) }
            let rects = pass.rectangles.map {
                RMReferenceRectangle(left: UInt16($0.left), top: UInt16($0.top), right: UInt16($0.right), bottom: UInt16($0.bottom))
            }
            let converted = expected.withUnsafeMutableBufferPointer { pixels in
                rm_reference_decode(
                    reference, layout, planes, strides, UInt32(CVPixelBufferGetHeight(pass.image)), rects, rects.count,
                    pixels.baseAddress, UInt32((width + 1) * 4))
            }
            #expect(converted)
            for r in pass.rectangles {
                for y in r.top..<min(r.bottom, pass.convertHeight) {
                    for x in r.left..<r.right { drawn[y * width + x] = true }
                    // FreeRDP's YUV444ToRGB converts pixel pairs, so an odd-width rectangle also overwrites the
                    // pixel to its right. The GPU draws only inside the rectangle, so that pixel is not compared.
                    if pass.layout != .yuv420, (r.right - r.left) % 2 == 1, r.right < width { drawn[y * width + r.right] = false }
                }
            }
        }
        #expect(try renderer.draw(target, passes: passes))
    }

    /// The first desktop pixel where the GPU's blue, green, or red differs from FreeRDP's surface pixel,
    /// or that the GPU drew outside the surface's visible area.
    func mismatch() throws -> String? {
        // A padded stride, as a GDI surface may have.
        let stride = target.desktopWidth * 4 + 12
        var actual = [UInt8](repeating: 0, count: stride * target.desktopHeight)
        try actual.withUnsafeMutableBytes {
            try renderer.read(
                [DirtyRectangle(x: 0, y: 0, width: target.desktopWidth, height: target.desktopHeight)], into: $0.baseAddress!,
                stride: stride, originX: 0, originY: 0)
        }
        for dy in 0..<target.desktopHeight {
            for dx in 0..<target.desktopWidth {
                let index = dy * stride + dx * 4
                let x = dx - target.originX
                let y = dy - target.originY
                guard x >= 0, y >= 0, x < target.visibleWidth, y < target.visibleHeight else {
                    if actual[index..<(index + 4)] != [0, 0, 0, 0] { return "(\(dx), \(dy)) outside the surface was drawn" }
                    continue
                }
                guard drawn[y * width + x] else { continue }
                let reference = (y * (width + 1) + x) * 4
                if actual[index..<(index + 3)] != expected[reference..<(reference + 3)] {
                    return "(\(x), \(y)): GPU \(Array(actual[index..<(index + 3)])), FreeRDP \(Array(expected[reference..<(reference + 3)]))"
                }
            }
        }
        return nil
    }
}

/// AVC420 converts each rectangle with its own chroma phase.
@Test func avc420MatchesFreeRDPByteForByte() throws {
    var random = SplitMix64(state: 420)
    // A surface height that is not a multiple of 16, so the picture is taller than the surface.
    let width = 90
    let height = 70
    let first = try picture(width: 96, height: 80, using: &random)
    var comparison = try Comparison(width: width, height: height, lumaStride: CVPixelBufferGetBytesPerRowOfPlane(first, 0))
    for frame in 0..<40 {
        let image = frame == 0 ? first : try picture(width: 96, height: 80, using: &random)
        try comparison.draw([
            .init(layout: .yuv420, image: image, rectangles: rectangles(width: width, height: height, using: &random), convertHeight: height)
        ])
        let mismatch = try comparison.mismatch()
        #expect(mismatch == nil, "frame \(frame): \(mismatch ?? "")")
        if mismatch != nil { return }
    }
}

/// AVC444 merges each view into persistent 4:4:4 planes, so a frame's pixels depend on every earlier frame.
@Test(arguments: [H264Renderer.Layout.chromaV1, .chromaV2])
func avc444MatchesFreeRDPByteForByte(chroma: H264Renderer.Layout) throws {
    var random = SplitMix64(state: chroma == .chromaV1 ? 1 : 2)
    // AVC444v2 places V at half the surface width aligned to 32, so the picture is exactly that wide.
    let width = 96
    let height = 70
    let first = try picture(width: width, height: 80, using: &random)
    var comparison = try Comparison(width: width, height: height, lumaStride: CVPixelBufferGetBytesPerRowOfPlane(first, 0))
    for frame in 0..<60 {
        // LC 0 sends both views, LC 1 only the main view, LC 2 only the auxiliary view.
        let layouts: [H264Renderer.Layout] =
            switch frame < 2 ? 0 : Int.random(in: 0...2, using: &random) {
            case 0: [.luma, chroma]
            case 1: [.luma]
            default: [chroma]
            }
        var passes: [H264Renderer.Pass] = []
        for layout in layouts {
            let image = frame == 0 && passes.isEmpty ? first : try picture(width: width, height: 80, using: &random)
            passes.append(
                .init(layout: layout, image: image, rectangles: rectangles(width: width, height: height, using: &random), convertHeight: height))
        }
        try comparison.draw(passes)
        let mismatch = try comparison.mismatch()
        #expect(mismatch == nil, "frame \(frame) \(layouts): \(mismatch ?? "")")
        if mismatch != nil { return }
    }
}

/// A surface placed away from the desktop's origin and cut off by its edges, as on a second monitor.
@Test func surfaceLandsAtItsOriginAndIsClippedToTheDesktop() throws {
    var random = SplitMix64(state: 7)
    let width = 64
    let height = 48
    let first = try picture(width: width, height: height, using: &random)
    var comparison = try Comparison(
        width: width, height: height, lumaStride: CVPixelBufferGetBytesPerRowOfPlane(first, 0), originX: 40, originY: 20,
        desktopWidth: 90, desktopHeight: 60)
    for frame in 0..<8 {
        let image = frame == 0 ? first : try picture(width: width, height: height, using: &random)
        try comparison.draw([
            .init(layout: .yuv420, image: image, rectangles: rectangles(width: width, height: height, using: &random), convertHeight: height)
        ])
        let luma = try picture(width: width, height: height, using: &random)
        try comparison.draw([
            .init(layout: .luma, image: luma, rectangles: rectangles(width: width, height: height, using: &random), convertHeight: height)
        ])
        let mismatch = try comparison.mismatch()
        #expect(mismatch == nil, "frame \(frame): \(mismatch ?? "")")
        if mismatch != nil { return }
    }
    // A read back of part of the desktop returns the same pixels as a read of all of it.
    let desktop = comparison.target
    var whole = [UInt8](repeating: 0, count: desktop.desktopWidth * desktop.desktopHeight * 4)
    try whole.withUnsafeMutableBytes {
        try comparison.renderer.read(
            [DirtyRectangle(x: 0, y: 0, width: desktop.desktopWidth, height: desktop.desktopHeight)], into: $0.baseAddress!,
            stride: desktop.desktopWidth * 4, originX: 0, originY: 0)
    }
    // Two rectangles read at once into an image of the area from (41, 21) to (66, 50), as a surface's pixels.
    let areas = [DirtyRectangle(x: 41, y: 21, width: 13, height: 7), DirtyRectangle(x: 60, y: 40, width: 6, height: 10)]
    let stride = 25 * 4 + 8
    var part = [UInt8](repeating: 0, count: stride * 29)
    try part.withUnsafeMutableBytes {
        try comparison.renderer.read(areas, into: $0.baseAddress!, stride: stride, originX: 41, originY: 21)
    }
    for area in areas {
        for row in area.y..<(area.y + area.height) {
            let start = (row * desktop.desktopWidth + area.x) * 4
            let offset = (row - 21) * stride + (area.x - 41) * 4
            #expect(part[offset..<(offset + area.width * 4)] == whole[start..<(start + area.width * 4)])
        }
    }
}

/// A GPU error discards the framebuffer once and tells the loss observers at once, so a session can ask the server
/// for a redraw before any later frame. The next draw reports the loss. Apple GPUs drop writes to bad addresses
/// instead of failing the command buffer, so the test reports the error as the command buffer's completion does.
@Test func gpuErrorDiscardsTheFramebufferOnceAndTellsLossObservers() throws {
    var random = SplitMix64(state: 3)
    let desktop = try MetalDesktop(device: #require(MTLCreateSystemDefaultDevice()))
    let renderer = try H264Renderer(desktop: desktop)
    let observed = Mutex(0)
    let observer = desktop.addLossObserver { observed.withLock { $0 += 1 } }
    defer { desktop.removeLossObserver(observer) }
    let target = H264Renderer.Target(
        surface: 1, surfaceWidth: 64, surfaceHeight: 48, originX: 0, originY: 0, visibleWidth: 64, visibleHeight: 48,
        desktopWidth: 64, desktopHeight: 48)
    func draw() throws -> Bool {
        let image = try picture(width: 64, height: 48, using: &random)
        return try renderer.draw(
            target, passes: [.init(layout: .yuv420, image: image, rectangles: [.init(left: 0, top: 0, right: 64, bottom: 48)], convertHeight: 48)])
    }

    #expect(try draw())
    var drawn: (any MTLTexture)?
    _ = try desktop.submit { texture, _ in drawn = texture }
    let lost = try #require(drawn)
    // A CPU update staged after the failed command holds a staging slot, which the discard must return.
    let update = [UInt8](repeating: 0, count: 64 * 48 * 4)
    _ = try update.withUnsafeBytes {
        try desktop.ingest(
            BorrowedFrame(pixels: $0.baseAddress!, width: 64, height: 48, stride: 256, dirtyRectangles: [.init(x: 0, y: 0, width: 8, height: 8)]))
    }
    desktop.discardFramebuffer(drawnInto: lost)
    #expect(observed.withLock { $0 } == 1)
    #expect(desktop.losses == 1)
    #expect(desktop.size == nil)

    #expect(try draw() == false)
    // A late error from the discarded framebuffer leaves the new one.
    desktop.discardFramebuffer(drawnInto: lost)
    #expect(observed.withLock { $0 } == 1)
    #expect(desktop.size == DesktopSize(width: 64, height: 48))
    #expect(try draw())
}
