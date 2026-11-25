import CFreeRDPBridge
import CFreeRDPGraphics
import Testing

/// Stands in for the GPU behind the video module: records what the module asks of it and answers as scripted.
private final class FakeGPU {
    struct Frame {
        let surface: UInt16
        let originX, originY, visibleWidth, visibleHeight: UInt32
        let layouts: [RMRDPVideoLayout]
        let rectangles: [Area]
    }
    struct Read {
        let areas: [Area]
        let originX, originY: UInt32
    }

    var frames: [Frame] = []
    /// Answers to the next frames, in order. Frames past the script are drawn.
    var results: [RMRDPVideoResult] = []
    var reads: [Read] = []
    var readSucceeds = true
    /// What a read back writes into the surface, 0xRRGGBB.
    let readColor: UInt32 = 0x112233
    /// Runs as each frame reaches the GPU, before it is drawn.
    var onDraw: (() -> Void)?

    static func of(_ user: UnsafeMutableRawPointer?) -> FakeGPU { Unmanaged<FakeGPU>.fromOpaque(user!).takeUnretainedValue() }

    func draw(_ frame: RMRDPVideoFrame) -> RMRDPVideoResult {
        onDraw?()
        let passes = withUnsafeBytes(of: frame.passes) { Array($0.bindMemory(to: RMRDPVideoPass.self).prefix(frame.pass_count)) }
        frames.append(
            Frame(
                surface: frame.surface, originX: frame.origin_x, originY: frame.origin_y, visibleWidth: frame.visible_width,
                visibleHeight: frame.visible_height, layouts: passes.map(\.layout),
                rectangles: passes.flatMap { UnsafeBufferPointer(start: $0.rectangles, count: $0.count).map(Area.init) }))
        return results.isEmpty ? RMRDP_VIDEO_DRAWN : results.removeFirst()
    }

    func read(
        _ rectangles: UnsafeBufferPointer<RMRDPVideoRectangle>, originX: UInt32, originY: UInt32,
        into pixels: UnsafeMutablePointer<UInt8>, stride: Int
    ) -> Bool {
        reads.append(Read(areas: rectangles.map(Area.init), originX: originX, originY: originY))
        guard readSucceeds else { return false }
        for area in rectangles {
            for y in Int(area.top)..<Int(area.bottom) {
                for x in Int(area.left)..<Int(area.right) {
                    let pixel = pixels + (y - Int(originY)) * stride + (x - Int(originX)) * 4
                    pixel[0] = UInt8(readColor & 0xff)
                    pixel[1] = UInt8((readColor >> 8) & 0xff)
                    pixel[2] = UInt8(readColor >> 16)
                }
            }
        }
        return true
    }
}

private struct Area: Equatable, CustomStringConvertible {
    let left, top, right, bottom: UInt16
    init(_ left: UInt16, _ top: UInt16, _ right: UInt16, _ bottom: UInt16) {
        (self.left, self.top, self.right, self.bottom) = (left, top, right, bottom)
    }
    init(_ r: RMRDPVideoRectangle) { self.init(r.left, r.top, r.right, r.bottom) }
    var c: RMRDPVideoRectangle { RMRDPVideoRectangle(left: left, top: top, right: right, bottom: bottom) }
    var description: String { "(\(left), \(top), \(right), \(bottom))" }
}

/// A 256x128 desktop whose graphics commands go through Remora's video module and FreeRDP's GDI.
private final class Desktop {
    let gpu = FakeGPU()
    let graphics: OpaquePointer
    /// The color of the IDR frame that every H.264 command carries.
    static let pictureColor: UInt32 = 0x3080C0

    init(refreshRect: Bool = true) throws {
        var callbacks = RMRDPCallbacks()
        callbacks.video_frame = { user, frame in FakeGPU.of(user).draw(frame!.pointee) }
        callbacks.video_read = { user, rectangles, count, originX, originY, pixels, stride in
            FakeGPU.of(user).read(
                UnsafeBufferPointer(start: rectangles, count: count), originX: originX, originY: originY, into: pixels!,
                stride: Int(stride))
        }
        graphics = try #require(rm_graphics_new(256, 128, refreshRect, &callbacks, Unmanaged.passUnretained(gpu).toOpaque()))
    }

    deinit { rm_graphics_free(graphics) }

    var session: OpaquePointer { rm_graphics_session(graphics) }

    /// A 64x64 surface. Mapped to the desktop when given a position.
    func surface(_ id: UInt16, width: UInt16 = 64, height: UInt16 = 64, at position: (x: UInt32, y: UInt32)? = nil) {
        #expect(rm_graphics_create_surface(graphics, id, width, height) == 0)
        if let position { #expect(rm_graphics_map(graphics, id, position.x, position.y) == 0) }
    }

    func h264(_ id: UInt16, _ codec: RMGraphicsCodec = RMGRAPHICS_AVC420, _ areas: [Area] = [Area(0, 0, 16, 16)]) {
        let rectangles = areas.map(\.c)
        #expect(rm_graphics_h264(graphics, id, codec, rectangles, rectangles.count) == 0)
    }

    func fill(_ id: UInt16, _ area: Area, _ color: UInt32) { #expect(rm_graphics_fill(graphics, id, area.c, color) == 0) }

    func planar(_ id: UInt16, _ area: Area, _ color: UInt32) { #expect(rm_graphics_planar(graphics, id, area.c, color) == 0) }

    func copy(_ from: UInt16, _ area: Area, to: UInt16, x: UInt16, y: UInt16) {
        #expect(rm_graphics_copy(graphics, from, area.c, to, x, y) == 0)
    }

    func cache(_ id: UInt16, _ area: Area, slot: UInt16) { #expect(rm_graphics_cache(graphics, id, area.c, slot) == 0) }

    func restore(slot: UInt16, to id: UInt16, x: UInt16, y: UInt16) {
        #expect(rm_graphics_restore(graphics, slot, id, x, y) == 0)
    }

    func startFrame() { #expect(rm_graphics_start_frame(graphics) == 0) }
    func endFrame() { #expect(rm_graphics_end_frame(graphics) == 0) }
    func surfacePixel(_ id: UInt16, _ x: UInt32, _ y: UInt32) -> UInt32 { rm_graphics_surface_pixel(graphics, id, x, y) }
    func desktopPixel(_ x: UInt32, _ y: UInt32) -> UInt32 { rm_graphics_desktop_pixel(graphics, x, y) }
    var refreshes: UInt32 { rm_graphics_refreshes(graphics) }
    var awaitsRedraw: Bool { rm_rdp_awaits_redraw(session) }
    /// Waits, then runs the display step and returns how many Refresh Rect requests went out.
    func after(_ milliseconds: Int) async throws -> UInt32 {
        try await Task.sleep(for: .milliseconds(milliseconds))
        return refreshes
    }
    var displayWoken: Bool { rm_graphics_display_woken(graphics) }
}

/// FreeRDP's CPU conversion of the IDR frame. FreeRDP converts with BT.709 and the encoder took BT.601, so the
/// colors differ by a few steps.
private func expectPicture(_ color: UInt32, sourceLocation: SourceLocation = #_sourceLocation) {
    let close = (0..<3).allSatisfy { shift in
        abs(Int((color >> (shift * 8)) & 0xff) - Int((Desktop.pictureColor >> (shift * 8)) & 0xff)) <= 8
    }
    #expect(close, "0x\(String(color, radix: 16)) is not the picture", sourceLocation: sourceLocation)
}

@Suite struct VideoRoutingTests {
    /// The surface's CPU pixels take the GPU-drawn area before another command reads them, and only once.
    @Test func gpuDrawnAreaIsReadBackBeforeAnotherCommandReadsTheSurface() throws {
        let desktop = try Desktop()
        desktop.surface(1, at: (0, 0))
        desktop.surface(2)
        desktop.h264(1, RMGRAPHICS_AVC420, [Area(0, 0, 16, 16)])
        #expect(desktop.gpu.frames.count == 1)
        #expect(desktop.gpu.reads.isEmpty)

        desktop.copy(1, Area(0, 0, 16, 16), to: 2, x: 8, y: 8)
        #expect(desktop.gpu.reads.map(\.areas) == [[Area(0, 0, 16, 16)]])
        #expect(desktop.surfacePixel(2, 10, 10) == desktop.gpu.readColor)
        desktop.copy(1, Area(0, 0, 16, 16), to: 2, x: 30, y: 30)
        #expect(desktop.gpu.reads.count == 1)
    }

    /// The server's cache must not keep stale pixels: a GPU-drawn area is read back before it is cached.
    @Test func gpuDrawnAreaIsReadBackBeforeItIsCached() throws {
        let desktop = try Desktop()
        desktop.surface(1, at: (0, 0))
        desktop.surface(2)
        desktop.h264(1, RMGRAPHICS_AVC420, [Area(0, 0, 16, 16)])
        desktop.cache(1, Area(0, 0, 16, 16), slot: 1)
        #expect(desktop.gpu.reads.map(\.areas) == [[Area(0, 0, 16, 16)]])
        desktop.restore(slot: 1, to: 2, x: 8, y: 8)
        #expect(desktop.surfacePixel(2, 10, 10) == desktop.gpu.readColor)
    }

    /// A restore from the cache lands on a surface whose GPU-drawn area is read back first, so a later read back
    /// cannot cover the restored pixels.
    @Test func gpuDrawnAreaIsReadBackBeforeACachedAreaIsRestoredOverIt() throws {
        let desktop = try Desktop()
        desktop.surface(1, at: (0, 0))
        desktop.surface(2, at: (128, 32))
        desktop.fill(1, Area(0, 0, 16, 16), 0xFF0000)
        desktop.cache(1, Area(0, 0, 16, 16), slot: 1)
        desktop.h264(2, RMGRAPHICS_AVC420, [Area(0, 0, 16, 16)])
        desktop.restore(slot: 1, to: 2, x: 8, y: 8)
        #expect(desktop.gpu.reads.map(\.areas) == [[Area(128, 32, 144, 48)]])
        #expect(desktop.surfacePixel(2, 4, 4) == desktop.gpu.readColor)
        #expect(desktop.surfacePixel(2, 10, 10) == 0xFF0000)
    }

    /// Windows mixes H.264 with codecs such as planar. A planar update lands on the surface's read-back pixels,
    /// reaches the desktop at the end of the frame, and leaves later H.264 on the GPU, with no redraw for AVC444.
    @Test func planarUpdateBetweenH264UpdatesDrawsOverTheReadBackPixels() throws {
        let desktop = try Desktop()
        desktop.surface(1, at: (0, 0))
        desktop.startFrame()
        desktop.h264(1, RMGRAPHICS_AVC444V2, [Area(0, 0, 16, 16)])
        desktop.planar(1, Area(8, 8, 24, 24), 0xFF0000)
        desktop.endFrame()
        #expect(desktop.gpu.reads.map(\.areas) == [[Area(0, 0, 16, 16)]])
        #expect(desktop.surfacePixel(1, 4, 4) == desktop.gpu.readColor)
        #expect(desktop.surfacePixel(1, 12, 12) == 0xFF0000)
        #expect(desktop.desktopPixel(12, 12) == 0xFF0000)

        desktop.h264(1, RMGRAPHICS_AVC444V2, [Area(32, 32, 48, 48)])
        #expect(desktop.gpu.frames.count == 2)
        #expect(desktop.refreshes == 0)
    }

    /// A server with two monitors maps one surface to each. Each draws on the GPU at its own position,
    /// and reads back from there.
    @Test func surfacesOfTwoMonitorsDrawOnTheGPUAtTheirOwnPositions() throws {
        let desktop = try Desktop()
        desktop.surface(1, at: (0, 0))
        desktop.surface(2, at: (128, 32))
        desktop.h264(1, RMGRAPHICS_AVC420, [Area(0, 0, 64, 64)])
        desktop.h264(2, RMGRAPHICS_AVC444V2, [Area(8, 8, 24, 24)])
        let frames = desktop.gpu.frames
        #expect(frames.map(\.surface) == [1, 2])
        #expect(frames.map { [$0.originX, $0.originY, $0.visibleWidth, $0.visibleHeight] } == [[0, 0, 64, 64], [128, 32, 64, 64]])
        #expect(frames.map(\.layouts) == [[RMRDP_VIDEO_YUV420], [RMRDP_VIDEO_LUMA, RMRDP_VIDEO_CHROMA_V2]])

        desktop.fill(2, Area(0, 0, 4, 4), 0xFF0000)
        let read = try #require(desktop.gpu.reads.first)
        #expect(read.areas == [Area(136, 40, 152, 56)])
        #expect([read.originX, read.originY] == [128, 32])
        #expect(desktop.surfacePixel(2, 10, 10) == desktop.gpu.readColor)
    }

    /// The desktop texture has no room for a surface that hangs off the desktop's right or bottom edge, so FreeRDP
    /// draws it.
    @Test(arguments: [(UInt32(220), UInt32(0)), (0, 100)])
    func surfacePartlyOffTheDesktopDrawsOnTheCPU(x: UInt32, y: UInt32) throws {
        let desktop = try Desktop()
        desktop.surface(1, at: (x, y))
        desktop.h264(1)
        #expect(desktop.gpu.frames.isEmpty)
        expectPicture(desktop.surfacePixel(1, 5, 5))
    }

    /// Without a read back the surface's CPU pixels are stale, so H.264 stops drawing on the GPU and the server redraws.
    @Test func failedReadBackMovesH264ToTheCPU() throws {
        let desktop = try Desktop()
        desktop.surface(1, at: (0, 0))
        desktop.h264(1)
        desktop.gpu.readSucceeds = false
        desktop.fill(1, Area(32, 32, 40, 40), 0xFF0000)
        #expect(desktop.gpu.reads.count == 1)
        #expect(desktop.refreshes == 1)

        desktop.h264(1)
        #expect(desktop.gpu.frames.count == 1)
        expectPicture(desktop.surfacePixel(1, 5, 5))
    }

    /// CPU drawing earlier in the frame reaches the desktop before the GPU draws over it. Other surfaces keep theirs
    /// until the end of the frame, so where they overlap, the desktop ends as it does with FreeRDP alone.
    @Test func gpuDrawSendsOnlyItsOwnSurfacesEarlierCPUDrawing() throws {
        func frame(_ desktop: Desktop, gpu: Bool) {
            desktop.surface(1, at: (0, 0))
            desktop.surface(2, width: 32, height: 32, at: (100, 0))
            desktop.surface(3, width: 32, height: 32, at: (116, 0))
            desktop.startFrame()
            desktop.fill(2, Area(0, 0, 32, 32), 0xFF0000)
            desktop.fill(3, Area(0, 0, 32, 32), 0x00FF00)
            desktop.fill(1, Area(16, 16, 32, 32), 0x0000FF)
            if gpu { desktop.h264(1, RMGRAPHICS_AVC420, [Area(16, 16, 32, 32)]) }
            desktop.fill(2, Area(0, 0, 32, 32), 0xFFFF00)
            desktop.endFrame()
        }
        let freeRDP = try Desktop()
        frame(freeRDP, gpu: false)
        let desktop = try Desktop()
        var underPicture: UInt32?
        var overlap: UInt32?
        desktop.gpu.onDraw = { [unowned desktop] in
            underPicture = desktop.desktopPixel(20, 20)
            overlap = desktop.desktopPixel(120, 5)
        }
        let untouched = desktop.desktopPixel(120, 5)
        frame(desktop, gpu: true)
        #expect(desktop.gpu.frames.count == 1)
        #expect(underPicture == 0x0000FF)
        #expect(overlap == untouched)
        #expect(desktop.desktopPixel(105, 5) == freeRDP.desktopPixel(105, 5))
        #expect(desktop.desktopPixel(120, 5) == freeRDP.desktopPixel(120, 5))
    }

    /// Failures count over the session and all its surfaces, including GPU errors noticed after the fact, and never
    /// end it.
    @Test func threeGPUFailuresMoveH264ToTheCPU() throws {
        let desktop = try Desktop()
        desktop.surface(1, at: (0, 0))
        desktop.surface(2, at: (128, 32))
        desktop.gpu.results = [RMRDP_VIDEO_FAILED, RMRDP_VIDEO_DRAWN, RMRDP_VIDEO_DRAWN_AFTER_LOSS, RMRDP_VIDEO_DRAWN, RMRDP_VIDEO_FAILED]
        var refreshes: [UInt32] = []
        for surface: UInt16 in [1, 2, 1, 2, 2, 1, 2] {
            desktop.h264(surface)
            refreshes.append(desktop.refreshes)
        }
        #expect(desktop.gpu.frames.map(\.surface) == [1, 2, 1, 2, 2])
        #expect(refreshes == [1, 1, 2, 2, 3, 3, 3])
        expectPicture(desktop.surfacePixel(1, 5, 5))
        expectPicture(desktop.surfacePixel(2, 5, 5))
    }

    /// A GPU error discards GPU drawing on every surface, so only drawing after it is read back.
    @Test func drawingLostToAGPUErrorIsNotReadBack() throws {
        let desktop = try Desktop()
        desktop.surface(1, at: (0, 0))
        desktop.surface(2, at: (128, 32))
        desktop.gpu.results = [RMRDP_VIDEO_DRAWN, RMRDP_VIDEO_DRAWN, RMRDP_VIDEO_DRAWN_AFTER_LOSS]
        desktop.h264(1, RMGRAPHICS_AVC420, [Area(0, 0, 16, 16)])
        desktop.h264(2, RMGRAPHICS_AVC420, [Area(0, 0, 16, 16)])
        desktop.h264(1, RMGRAPHICS_AVC420, [Area(32, 32, 48, 48)])
        #expect(desktop.refreshes == 1)
        desktop.fill(2, Area(60, 60, 64, 64), 0xFF0000)
        desktop.fill(1, Area(60, 60, 64, 64), 0xFF0000)
        #expect(desktop.gpu.reads.map(\.areas) == [[Area(32, 32, 48, 48)]])
    }

    /// AVC444 keeps 4:4:4 planes on each path, so a surface that changes path asks the server for fresh views.
    /// AVC420 keeps no such state.
    @Test(arguments: [RMGRAPHICS_AVC444, RMGRAPHICS_AVC444V2, RMGRAPHICS_AVC420])
    func avc444SurfaceThatChangesPathAsksForARedraw(codec: RMGraphicsCodec) throws {
        let desktop = try Desktop()
        let redraws: UInt32 = codec == RMGRAPHICS_AVC420 ? 0 : 1
        desktop.surface(1, at: (0, 0))
        desktop.h264(1, codec)
        #expect(desktop.refreshes == 0)

        // An overlapping surface sends surface 1 to FreeRDP's CPU path.
        desktop.surface(2, width: 16, height: 16, at: (32, 32))
        desktop.h264(1, codec)
        desktop.h264(1, codec)
        #expect(desktop.gpu.frames.count == 1)
        #expect(desktop.refreshes == redraws)

        #expect(rm_graphics_delete_surface(desktop.graphics, 2) == 0)
        desktop.h264(1, codec)
        #expect(desktop.gpu.frames.count == 2)
        #expect(desktop.refreshes == 2 * redraws)
    }

    /// A redraw request needs no frame to go out, and a server that does not honor Refresh Rect never gets one.
    @Test(arguments: [true, false]) func redrawRequestReachesTheServerWithoutAFrame(refreshRect: Bool) throws {
        let desktop = try Desktop(refreshRect: refreshRect)
        _ = desktop.refreshes
        #expect(!desktop.displayWoken)
        rm_rdp_request_refresh(desktop.session)
        #expect(desktop.displayWoken)
        #expect(desktop.refreshes == (refreshRect ? 1 : 0))
        #expect(desktop.refreshes == (refreshRect ? 1 : 0))
    }

    /// A hidden tab's server keeps sending updates for two seconds before it is paused, and redraws meanwhile.
    @Test func redrawRequestOfAHiddenTabGoesOutBeforeThePause() throws {
        let desktop = try Desktop()
        rm_rdp_set_display_updates(desktop.session, false)
        _ = desktop.refreshes
        rm_rdp_request_refresh(desktop.session)
        #expect(desktop.refreshes == 1)
    }

    /// Windows answers a resume with a blank placeholder before the redraw, so the redraw counts as arrived 100 ms
    /// after the first frame that follows the resume's request. A late answer to an earlier resume never counts.
    @Test func aResumesRedrawArrivesShortlyAfterItsOwnFirstFrame() async throws {
        let desktop = try Desktop()
        desktop.surface(1, at: (0, 0))
        let show = { rm_rdp_set_display_updates(desktop.session, $0) }
        // A resume that has no answer yet. A pause goes out 2 s after hiding, a resume 1 s after the pause.
        show(false)
        #expect(try await desktop.after(2010) == 0)
        show(true)
        #expect(try await desktop.after(1010) == 1)
        #expect(desktop.awaitsRedraw)

        // Its answer comes after the next pause, just before the next resume is wanted.
        show(false)
        _ = try await desktop.after(2010)
        desktop.h264(1)
        show(true)
        #expect(try await desktop.after(120) == 1)
        #expect(desktop.awaitsRedraw)
        #expect(try await desktop.after(860) == 2)

        // Again, but the answer comes after the next resume is wanted and before its request goes out.
        show(false)
        _ = try await desktop.after(2010)
        show(true)
        desktop.h264(1)
        #expect(try await desktop.after(120) == 2)
        #expect(desktop.awaitsRedraw)
        #expect(try await desktop.after(860) == 3)
        #expect(desktop.gpu.frames.count == 2)

        // The resume's own first frame, such as the placeholder, counts 100 ms later.
        let start = ContinuousClock.now
        desktop.h264(1)
        _ = desktop.refreshes
        #expect(desktop.awaitsRedraw || ContinuousClock.now - start >= .milliseconds(100))
        _ = try await desktop.after(120)
        #expect(!desktop.awaitsRedraw)
    }
}
