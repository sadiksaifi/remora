import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Metal
import Synchronization
import Testing

@testable import RemoraCore

private func desktop(width: Int, height: Int, bgra: [UInt8], sink: MetalDesktop) {
    // Padded rows catch accidental use of tightly packed source strides.
    let stride = width * 4 + 16
    var pixels = [UInt8](repeating: 0, count: stride * height)
    for y in 0..<height {
        for x in 0..<width { pixels.replaceSubrange((y * stride + x * 4)..<(y * stride + x * 4 + 4), with: bgra) }
    }
    _ = pixels.withUnsafeBytes {
        try! sink.ingest(
            BorrowedFrame(
                pixels: $0.baseAddress!, width: width, height: height, stride: stride,
                dirtyRectangles: [.init(x: 0, y: 0, width: 1, height: 1)]))
    }
    // Destroy the borrowed storage. A later screenshot must retain the whole desktop.
    _ = pixels.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
}

@Test func frameIsBlankOnlyWhenBlackAllOver() {
    func frame(_ edit: (inout [UInt8]) -> Void) -> CaptureFrame {
        var pixels = [UInt8](repeating: 0, count: 256 * 128 * 4)
        edit(&pixels)
        return pixels.withUnsafeBytes {
            CaptureFrame(copying: BorrowedFrame(pixels: $0.baseAddress!, width: 256, height: 128, stride: 256 * 4, dirtyRectangles: []))
        }
    }
    #expect(frame { _ in }.isBlank)
    // Codec noise in black, as in a Windows server's first frames.
    #expect(frame { $0[2] = 1 }.isBlank)
    // One lit taskbar row at the bottom.
    #expect(!frame { pixels in for index in (126 * 256 * 4)..<(127 * 256 * 4) { pixels[index] = 200 } }.isBlank)
}

@Test func desktopReadbackLeavesChangedFramePendingForPresentation() throws {
    let frames = try MetalDesktop(device: #require(MTLCreateSystemDefaultDevice()))
    desktop(width: 2, height: 1, bgra: [0, 0, 0, 255], sink: frames)
    let baseline = try frames.snapshot()
    #expect(baseline.isBlank)
    // Model a window that has already presented this black baseline.
    let displayedRevision = baseline.revision
    let pixels: [UInt8] = [0, 0, 0, 255, 17, 91, 203, 255]
    _ = try pixels.withUnsafeBytes {
        try frames.ingest(
            BorrowedFrame(
                pixels: $0.baseAddress!, width: 2, height: 1, stride: 8,
                dirtyRectangles: [.init(x: 1, y: 0, width: 1, height: 1)]))
    }
    // A connect readiness check must not satisfy the window's demand for this update.
    let captured = try frames.snapshot()
    #expect(Array(captured.pixels) == [0, 0, 0, 255, 17, 91, 203, 255])
    #expect(!captured.isBlank)
    #expect(frames.needsSubmission(since: displayedRevision, redraw: false))
    #expect(!frames.needsSubmission(since: captured.revision, redraw: false))
}

@Test @MainActor func idleHiddenDesktopReadbackWritesCompleteOpaquePNG() async throws {
    let frames = try MetalDesktop(device: #require(MTLCreateSystemDefaultDevice()))
    desktop(width: 8, height: 6, bgra: [21, 87, 231, 0], sink: frames)
    let capture = SessionCapture(media: AppleCaptureMedia(), destination: ScreenshotDestination())
    capture.setSource(frames)
    // No display link, drawable, recorder, or further frame callback. This is a hidden, idle desktop.
    let png = try await capture.screenshotPNG()
    let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 8)
    #expect(image.height == 6)
    var rgba = [UInt8](repeating: 0, count: 8 * 6 * 4)
    try rgba.withUnsafeMutableBytes {
        let context = try #require(
            CGContext(
                data: $0.baseAddress, width: 8, height: 6, bitsPerComponent: 8,
                bytesPerRow: 32, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 6))
    }
    for offset in stride(from: 0, to: rgba.count, by: 4) {
        #expect(Array(rgba[offset..<offset + 4]) == [231, 87, 21, 255])
    }
    // An unused staging slot contains poison outside this dirty pixel. Do not upload its holes.
    var update = [UInt8](repeating: 0, count: 8 * 6 * 4)
    update.replaceSubrange((update.count - 4)..<update.count, with: [201, 31, 17, 0])
    let copied = try update.withUnsafeBytes {
        try frames.ingest(
            BorrowedFrame(
                pixels: $0.baseAddress!, width: 8, height: 6, stride: 32,
                dirtyRectangles: [.init(x: 7, y: 5, width: 1, height: 1)]))
    }
    #expect(copied == 4)
    // A failed consumer must still commit its queued upload and return the staging slot.
    #expect(throws: CaptureFailure.self) {
        try frames.submit { _, _ in throw CaptureFailure.image("Synthetic encoding failure") }
    }
    let idle = try frames.snapshot()
    #expect(Array(idle.pixels.suffix(4)) == [201, 31, 17, 0])
    #expect(Array(idle.pixels.prefix(4)) == [21, 87, 231, 0])
}

private struct RecordingTestDestination: CaptureDestination {
    let url: URL
    func reserve(connectionName: String, extension suffix: String) throws -> URL {
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            throw CaptureFailure.file("Could not reserve test movie")
        }
        return url
    }
}

@Test @MainActor func concurrentRecordingStopsObservePublishedCompletion() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("concurrent.mov")
    let frames = try MetalDesktop(device: #require(MTLCreateSystemDefaultDevice()))
    desktop(width: 320, height: 240, bgra: [20, 30, 240, 0], sink: frames)
    let capture = SessionCapture(media: AppleCaptureMedia(), destination: RecordingTestDestination(url: url))
    capture.setSource(frames)
    var concurrentStop: Task<Void, Never>?
    capture.onRecordingActivityChange = { active in
        guard !active else { return }
        concurrentStop = Task {
            let result = await capture.stopRecording()
            #expect((try? result?.get()) == url)
            #expect(capture.recordingState == .idle)
            #expect(capture.recordingURL == nil)
            #expect(capture.lastSavedURL == url)
        }
    }
    try capture.startRecording(connectionName: "Test")
    let result = await capture.stopRecording()
    #expect(try result?.get() == url)
    await concurrentStop?.value
    #expect(try await capture.stopRecording()?.get() == url)
}

@Test func hardwareMovieSurvivesResizeAndIncludesIdleTime() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("synthetic.mov")
    #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
    let frames = try MetalDesktop(device: #require(MTLCreateSystemDefaultDevice()))
    desktop(width: 320, height: 240, bgra: [20, 30, 240, 0], sink: frames)
    let overlays = SessionOverlayState()
    let cursor = try #require(
        CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    cursor.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
    cursor.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    overlays.setCursor(cursor.makeImage(), hotspot: CGPoint(x: 16, y: 16))
    let movie = try AppleCaptureMedia(overlays: overlays).movie(at: url, source: frames)
    let observer = frames.addFrameObserver { movie.submit(arrival: $0) }
    try await Task.sleep(for: .milliseconds(180))
    desktop(width: 160, height: 240, bgra: [30, 240, 20, 0], sink: frames)
    overlays.receive(.human, .pointer(.init(x: 0, y: 120), []))
    // Exercise latest-frame coalescing faster than the 60 fps limit.
    let green: [UInt8] = [30, 240, 20, 0]
    var burst = Array(repeating: green, count: 160 * 240).flatMap { $0 }
    for offset in stride(from: 0, to: 160 * 80 * 4, by: 4) {
        burst.replaceSubrange(offset..<offset + 4, with: [230, 30, 20, 0])
    }
    for index in 0..<40 {
        burst[0] = UInt8(index)
        _ = burst.withUnsafeBytes {
            try! frames.ingest(
                BorrowedFrame(
                    pixels: $0.baseAddress!, width: 160, height: 240, stride: 640,
                    dirtyRectangles: [.init(x: 0, y: 0, width: index == 0 ? 160 : 1, height: index == 0 ? 80 : 1)]))
        }
    }
    try await Task.sleep(for: .milliseconds(520))
    frames.removeFrameObserver(observer)
    let result = await movie.finish()
    _ = try result.get()
    let asset = AVURLAsset(url: url)
    #expect(try await asset.load(.isPlayable))
    let duration = try await asset.load(.duration).seconds
    #expect(duration >= 0.65 && duration < 2)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try #require(tracks.first)
    #expect(try await track.load(.naturalSize) == CGSize(width: 320, height: 240))
    let formats = try await track.load(.formatDescriptions)
    #expect(CMFormatDescriptionGetMediaSubType(try #require(formats.first)) == kCMVideoCodecType_HEVC)
    #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
    reader.add(output)
    #expect(reader.startReading())
    var lastBuffer: CVPixelBuffer?
    var times: [Double] = []
    while let sample = output.copyNextSampleBuffer() {
        lastBuffer = CMSampleBufferGetImageBuffer(sample)
        if times.isEmpty, let buffer = lastBuffer {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            // The initial same-size frame takes the direct GPU blit path, with undefined alpha.
            #expect(pixels[2] > 210 && pixels[1] < 55 && pixels[0] < 55)
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
    }
    #expect(reader.status == .completed)
    #expect(times.count >= 2 && times.count <= 4)
    for pair in zip(times, times.dropFirst()) { #expect(pair.1 - pair.0 >= 1.0 / 60 - 0.0001) }
    let buffer = try #require(lastBuffer)
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let pixels = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let edge = 120 * stride + 10 * 4
    #expect(pixels[edge] < 12 && pixels[edge + 1] < 12 && pixels[edge + 2] < 12)
    // Half the cursor extends past the resized desktop's left edge. Only the desktop half is visible.
    let bar = 120 * stride + 68 * 4
    #expect(pixels[bar] < 12 && pixels[bar + 1] < 12 && pixels[bar + 2] < 12)
    let pointer = 120 * stride + 84 * 4
    #expect(pixels[pointer] > 180 && pixels[pointer + 1] < 80 && pixels[pointer + 2] > 180)
    let center = 120 * stride + 160 * 4
    #expect(pixels[center + 1] > 210)
    let top = 40 * stride + 160 * 4
    #expect(pixels[top] > 200 && pixels[top + 1] < 55)
}

@Test(arguments: [0, 2]) func movieHoldsLastFrameUntilStop(changes: Int) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("static.mov")
    #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
    let frames = try MetalDesktop(device: #require(MTLCreateSystemDefaultDevice()))
    desktop(width: 320, height: 240, bgra: [20, 30, 240, 0], sink: frames)
    let startedAt = ProcessInfo.processInfo.systemUptime
    let movie = try AppleCaptureMedia().movie(at: url, source: frames)
    let observer = frames.addFrameObserver { movie.submit(arrival: $0) }
    for change in 0..<changes {
        try await Task.sleep(for: .milliseconds(100))
        desktop(width: 320, height: 240, bgra: [UInt8(40 + change), 30, 240, 0], sink: frames)
    }
    // No more source frames. Exceed the encoder's default last-sample duration.
    try await Task.sleep(for: .milliseconds(1350))
    frames.removeFrameObserver(observer)
    let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
    _ = try await movie.finish().get()
    let asset = AVURLAsset(url: url)
    #expect(try await asset.load(.isPlayable))
    let duration = try await asset.load(.duration).seconds
    #expect(abs(duration - elapsed) < 0.15)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    #expect(abs(try await track.load(.timeRange).duration.seconds - elapsed) < 0.15)
    // AVFoundation extends edit-list timing even when the encoded media ends early.
    let mediaDuration = try #require(movieMediaDuration(Data(contentsOf: url)))
    #expect(mediaDuration >= elapsed - 0.15)
}

/// Read the video-only movie's media header, independent of AVFoundation's edit-list expansion.
private func movieMediaDuration(_ data: Data, range: Range<Int>? = nil) -> Double? {
    let range = range ?? 0..<data.count
    func integer(_ start: Int, bytes: Int = 4) -> UInt64 {
        data[start..<start + bytes].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    var offset = range.lowerBound
    while offset + 8 <= range.upperBound {
        let size = Int(integer(offset))
        guard size >= 8, offset + size <= range.upperBound else { return nil }
        let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
        if type == "mdhd" {
            guard size >= 32 else { return nil }
            let version = data[offset + 8]
            let field = offset + (version == 1 ? 28 : 20)
            let bytes = version == 1 ? 8 : 4
            guard version <= 1, field + 4 + bytes <= offset + size, integer(field) > 0 else { return nil }
            return Double(integer(field + 4, bytes: bytes)) / Double(integer(field))
        }
        if ["moov", "trak", "mdia"].contains(type),
            let duration = movieMediaDuration(data, range: offset + 8..<offset + size)
        {
            return duration
        }
        offset += size
    }
    return nil
}

@Test func screenshotDestinationSavesToTheChosenFolder() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = try ScreenshotDestination(folder: { folder }).reserve(connectionName: "Lab PC", extension: "png")
    #expect(url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
}

/// A clock that stands still until the test moves it. The overlays read it, so the test decides how far an
/// animation has run and the encoder's speed decides nothing.
private final class OverlayClock: Sendable {
    private let now = Mutex(ProcessInfo.processInfo.systemUptime)
    var time: TimeInterval { now.withLock { $0 } }
    func advance(by seconds: TimeInterval) { now.withLock { $0 += seconds } }
}

/// A recording of overlays that run on the test's clock.
private struct OverlayRecording {
    let clock: OverlayClock
    let movie: AppleCaptureMovie
    /// The clock's time at each frame the test has waited for. Each wait yields one frame, in order.
    private var times: [TimeInterval] = []
    var written: Int { times.count }

    init(_ media: AppleCaptureMedia, at url: URL, source: MetalDesktop, clock: OverlayClock) throws {
        self.clock = clock
        movie = try #require(try media.movie(at: url, source: source) as? AppleCaptureMovie)
    }

    /// Waits until the movie has written the frame for the clock's time, and returns that frame's index.
    /// Only the overlays tell the movie about that time: their animation timer after the test moves the clock,
    /// or a change the test makes. The wait lasts as long as the encoder needs.
    @discardableResult
    mutating func frame() async throws -> Int {
        let deadline = ContinuousClock.now + .seconds(10)
        while movie.writtenArrival < clock.time {
            try #require(ContinuousClock.now < deadline, "The movie wrote no frame for the overlays' time.")
            try await Task.sleep(for: .milliseconds(2))
        }
        times.append(clock.time)
        return written - 1
    }

    /// Moves the clock on while an animation runs, and waits for the frame its timer wakes.
    @discardableResult
    mutating func frame(after seconds: TimeInterval) async throws -> Int {
        clock.advance(by: seconds)
        return try await frame()
    }

    /// Finishes the movie and reads its frames back in order. The movie starts on the overlays' clock, so each
    /// frame is timed as far into the movie as the test had moved the clock, and the movie plays an animation
    /// at its own speed. The movie holds no frame that the test did not wait for.
    func finish() async throws -> [CVPixelBuffer] {
        let url = try await movie.finish().get()
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        #expect(reader.startReading())
        var shots: [CVPixelBuffer] = []
        var shown: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            shots.append(try #require(CMSampleBufferGetImageBuffer(sample)))
            shown.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        // The movie can repeat its last frame to last until it stops. Its file rounds a frame's time to 1/600 s.
        try #require(shots.count == written || shots.count == written + 1)
        for frame in times.indices {
            let (movie, clock) = (shown[frame], times[frame] - times[0])
            #expect(abs(movie - clock) < 0.005, "frame \(frame): the movie shows it at \(movie) s, the clock at \(clock) s")
        }
        return shots
    }
}

private func rgb(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> [Int] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let bytes =
        CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
    return [Int(bytes[2]), Int(bytes[1]), Int(bytes[0])]
}

@Test func recordingFeedbackAnimatesOnIdleDesktopWithoutChangingScreenshots() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("feedback.mov")
    #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
    let frames = try MetalDesktop(device: #require(MTLCreateSystemDefaultDevice()))
    desktop(width: 640, height: 360, bgra: [80, 80, 80, 0], sink: frames)
    let clock = OverlayClock()
    let overlays = SessionOverlayState(clock: { clock.time })
    overlays.configure(showPointerInRecordings: true, showKeyPresses: true, showAgentPointer: true, scale: 1)
    let cursorContext = try #require(
        CGContext(
            data: nil, width: 20, height: 20, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    cursorContext.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
    cursorContext.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
    overlays.setCursor(cursorContext.makeImage(), hotspot: CGPoint(x: 5, y: 7))
    overlays.receive(.human, .pointer(.init(x: 100, y: 100), .left))
    let media = AppleCaptureMedia(overlays: overlays)
    let rawPNG = try media.png(frames.snapshot())
    var recording = try OverlayRecording(media, at: url, source: frames, clock: clock)
    let idle = try await recording.frame()
    overlays.receive(.human, .key(scancode: 0x0F, down: true))
    // There are no frame observers or additional decoded frames, and the test only moves the clock from here
    // on. The pill shows at full strength for 1.25 s, fades until 1.5 s after the key press, and is then removed.
    let shown = try await recording.frame(after: 0.5)
    #expect(try media.png(frames.snapshot()) == rawPNG)
    let held = try await recording.frame(after: 0.5)
    let fading = try await recording.frame(after: 0.375)
    let faded = try await recording.frame(after: 0.2)
    // Nothing animates now, so the timer has stopped and only this change wakes the movie.
    clock.advance(by: 0.1)
    overlays.configure(showPointerInRecordings: false, showKeyPresses: false, showAgentPointer: true, scale: 1)
    let disabled = try await recording.frame()
    let shots = try await recording.finish()
    #expect(try media.png(frames.snapshot()) == rawPNG)
    // The hotspot puts the cursor at (95,93), rather than centering it on the point. The pill does not hide it.
    for shot in [idle, shown] {
        #expect(rgb(shots[shot], 98, 96)[0] > 180)
        #expect(rgb(shots[shot], 98, 96)[2] > 180)
        #expect(rgb(shots[shot], 98, 96)[1] < 80)
    }
    // Inside the light glass, above the Tab keycap, the gray desktop is tinted toward white.
    let glass = { (shot: Int) in rgb(shots[shot], 320, 255) }
    #expect(glass(idle).allSatisfy { abs($0 - 80) < 8 })
    #expect(glass(shown).allSatisfy { $0 > 120 })
    #expect(glass(held).allSatisfy { $0 > 120 })
    // Halfway through its fade the pill tints the desktop about half as much.
    #expect(zip(glass(fading), glass(held)).allSatisfy { $0 > 80 + ($1 - 80) / 4 && $0 < 80 + ($1 - 80) * 3 / 4 })
    // The pill is gone and the cursor still shows. Turning the overlays off removes the cursor.
    #expect(glass(faded).allSatisfy { abs($0 - 80) < 8 })
    #expect(rgb(shots[faded], 98, 96)[0] > 180)
    #expect(rgb(shots[disabled], 98, 96).allSatisfy { abs($0 - 80) < 8 })
    #expect(rgb(try #require(shots.last), 98, 96).allSatisfy { abs($0 - 80) < 8 })
}

@Test(arguments: [1.0, 2.0]) func recordingAgentCursorMovesAndPressesWithoutAScreenObserver(unit: Double) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("agent-cursor.mov")
    #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
    let frames = try MetalDesktop(device: #require(MTLCreateSystemDefaultDevice()))
    desktop(width: 640, height: 360, bgra: [80, 80, 80, 0], sink: frames)
    let clock = OverlayClock()
    let state = SessionOverlayState(clock: { clock.time })
    state.configure(showPointerInRecordings: true, showKeyPresses: false, showAgentPointer: false, scale: unit)
    state.setDesktopSize(CGSize(width: 640, height: 360))
    state.setAgentCursorVisible(true)
    state.setAgentCursorBusy(true)
    state.moveAgentCursor(to: CGPoint(x: 80, y: 180), animated: false)
    let media = AppleCaptureMedia(overlays: state)
    let png = try media.png(frames.snapshot())
    var recording = try OverlayRecording(media, at: url, source: frames, clock: clock)
    try await recording.frame()
    // The cursor appears, then settles. A settled cursor stops the overlays' timer, so the test moves the clock
    // only while the cursor is unsettled.
    func settle() async throws -> Int {
        var last = recording.written - 1
        for _ in 0..<20 where state.snapshot().agentCursor?.isSettled == false { last = try await recording.frame(after: 0.25) }
        try #require(state.snapshot().agentCursor?.isSettled == true, "The cursor did not settle in 5 s.")
        return last
    }
    _ = try await settle()
    // Three legs, out, back and out again. The test only moves the clock while a leg travels, in six steps, so
    // each leg's frames come from the overlays' timer. A leg's frames start with the cursor at rest.
    var legs: [(frames: ClosedRange<Int>, outbound: Bool)] = []
    for (index, x) in [500.0, 80, 500].enumerated() {
        let start = recording.written - 1
        let arrival = state.moveAgentCursor(to: CGPoint(x: x, y: index == 1 ? 180 : 140), animated: true)
        for _ in 0..<6 { try await recording.frame(after: arrival / 6) }
        legs.append((start...(try await settle()), index != 1))
    }
    let resting = recording.written - 1
    state.pressAgentCursor(depth: CursorTuning.clickDepth, animated: true)
    state.receive(.agent, .pointer(.init(x: 500, y: 140), .left))
    var pressed: [Int] = []
    for _ in 0..<3 { pressed.append(try await recording.frame(after: 0.05)) }
    pressed.append(try await settle())
    state.releaseAgentCursor()
    try await recording.frame(after: 0.2)
    let released = try await settle()
    state.receive(.human, .pointer(.init(x: 200, y: 100), .left))
    let human = try await recording.frame(after: 0.05)
    let shots = try await recording.finish()
    #expect(try media.png(frames.snapshot()) == png)
    #expect(state.snapshot().clicks.allSatisfy { $0.source == .human })

    /// The horizontal center of the bright cursor pixels.
    func center(_ buffer: CVPixelBuffer) -> Double? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var sum = 0.0
        var pixels = 0.0
        for y in 60..<230 {
            for x in 40..<550 where bytes[y * stride + x * 4 + 2] > 145 {
                sum += Double(x)
                pixels += 1
            }
        }
        return pixels > 0 ? sum / pixels : nil
    }
    // Every frame of a leg shows the cursor.
    let centers = try legs.map { leg in try leg.frames.map { try #require(center(shots[$0])) } }
    // The cursor travels between resting centers near x 84-96 and 504-514, and a spring settles it at each.
    // Progress is the center along the leg's direction, from the first frame that leaves the start to the end
    // of the leg. It is capped at the destination band's edge, so the spring's recoil there counts as
    // arrived. Each frame stays within 1 px of the furthest progress so far, so a step back, a slide back in small
    // steps, a jump to the start, or a jump back from the destination fails. Compression moves a still cursor's
    // measured center by up to about 0.25 px.
    // In every leg, two frames between the bands are more than 20 px apart, and the leg covers 200 px.
    let progress = zip(legs, centers).map { leg, centers in
        let along = centers.map { leg.outbound ? $0 : -$0 }
        let arrived: Double = leg.outbound ? 500 : -105
        return along.drop { $0 < (leg.outbound ? 105 : -500) }.map { min($0, arrived) }
    }
    func advances(_ along: [Double]) -> Bool {
        var furthest = -Double.infinity
        return along.allSatisfy { value in
            defer { furthest = max(furthest, value) }
            return value > furthest - 1
        }
    }
    let travel = "centers by leg: \(centers.map { $0.map { ($0 * 10).rounded() / 10 } })"
    #expect(progress.allSatisfy(advances), "\(travel)")
    let travelled = zip(legs, progress).map { leg, along in along.filter { $0 < (leg.outbound ? 500 : -105) } }
    #expect(travelled.allSatisfy { ($0.last ?? 0) - ($0.first ?? 0) > 20 }, "\(travel)")
    #expect(centers.allSatisfy { ($0.max() ?? 0) - ($0.min() ?? 0) > 200 }, "\(travel)")
    let rest = shots[resting]
    // The stroke covers the target tip. The fill is the specified premultiplied slate mixture.
    #expect(rgb(rest, 500, 140).allSatisfy { $0 > 145 })
    let fill = rgb(rest, 500 + Int(6 * unit), 140 + Int(6 * unit))
    for (actual, expected) in zip(fill, [90, 105, 124]) { #expect(abs(actual - expected) < 18) }
    // Halo at 12 points right of its center: F over gray, followed by the white lift.
    let halo = rgb(rest, 500 + Int(15 * unit), 140 + Int(4 * unit))
    for (actual, expected) in zip(halo, [68, 79, 90]) { #expect(abs(actual - expected) < 12) }
    // Pixels of the glyph, which differ from the gray desktop by more than the faint halo does.
    func glyphArea(_ buffer: CVPixelBuffer) -> Int {
        var area = 0
        for y in (140 - Int(10 * unit))..<(140 + Int(40 * unit)) {
            for x in (500 - Int(10 * unit))..<(500 + Int(40 * unit)) where rgb(buffer, x, y).contains(where: { abs($0 - 80) > 30 }) {
                area += 1
            }
        }
        return area
    }
    // Pressing shrinks the glyph about the same target tip. The frames come 0.05 s, 0.1 s and 0.15 s after the
    // press and once the press has settled. The last two show it pressed.
    for press in pressed.suffix(2) { #expect(Double(glyphArea(shots[press])) < 0.85 * Double(glyphArea(rest))) }
    // Releasing brings the glyph back to its resting size.
    #expect(abs(Double(glyphArea(shots[released])) - Double(glyphArea(rest))) < 0.03 * Double(glyphArea(rest)))
    // Every pressed frame shows no agent click ring at radius 14. An erroneous ring fades over 0.5 s.
    for press in pressed {
        #expect(rgb(shots[press], 500 + Int(14 * unit), 140)[2] < 135)
        #expect(rgb(shots[press], 500, 140).allSatisfy { $0 > 125 })
    }
    // The user's ring appears 0.05 s after the click, away from the agent sprite. The frame before the click
    // shows the gray desktop at this point.
    #expect(rgb(shots[human], 200 + Int(14 * unit), 100)[2] > 150)
    #expect(rgb(shots[human - 1], 200 + Int(14 * unit), 100)[2] < 135)
}
