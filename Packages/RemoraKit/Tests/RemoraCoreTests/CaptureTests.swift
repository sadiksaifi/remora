import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Metal
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

@Test func recordingFeedbackAnimatesOnIdleDesktopWithoutChangingScreenshots() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("feedback.mov")
    #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
    let frames = try MetalDesktop(device: #require(MTLCreateSystemDefaultDevice()))
    desktop(width: 640, height: 360, bgra: [80, 80, 80, 0], sink: frames)
    let overlays = SessionOverlayState()
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
    let startedAt = ProcessInfo.processInfo.systemUptime
    let movie = try media.movie(at: url, source: frames)
    // The pill appears after the encoder's warm-up, which held the second frame back 0.5 s on the CI runner.
    try await Task.sleep(for: .seconds(1))
    let pillAt = ProcessInfo.processInfo.systemUptime - startedAt
    overlays.receive(.human, .key(scancode: 0x0F, down: true))
    // There are no frame observers or additional decoded frames. Only overlay invalidations wake the movie.
    try await Task.sleep(for: .milliseconds(1750))
    overlays.configure(showPointerInRecordings: false, showKeyPresses: false, showAgentPointer: true, scale: 1)
    try await Task.sleep(for: .milliseconds(120))
    _ = try await movie.finish().get()
    #expect(try media.png(frames.snapshot()) == rawPNG)
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    #expect(reader.startReading())
    var first: CVPixelBuffer?
    var faded: CVPixelBuffer?
    var disabled: CVPixelBuffer?
    var times: [Double] = []
    while let sample = output.copyNextSampleBuffer() {
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        if first == nil && time > pillAt + 0.05 { first = CMSampleBufferGetImageBuffer(sample) }
        if time > pillAt + 1.49 && time < pillAt + 1.7 { faded = CMSampleBufferGetImageBuffer(sample) }
        disabled = CMSampleBufferGetImageBuffer(sample)  // Finish drains the frame rendered after `configure`.
        times.append(time)
    }
    func rgb(_ buffer: CVPixelBuffer, x: Int, y: Int) -> [Int] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let p =
            CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return [Int(p[2]), Int(p[1]), Int(p[0])]
    }
    let initial = try #require(first)
    // The hotspot puts the cursor at (95,93), rather than centering it on the point.
    #expect(rgb(initial, x: 98, y: 96)[0] > 180)
    #expect(rgb(initial, x: 98, y: 96)[2] > 180)
    #expect(rgb(initial, x: 98, y: 96)[1] < 80)
    // Inside the light glass, above the Tab keycap, the gray desktop is tinted toward white.
    #expect(rgb(initial, x: 320, y: 255).allSatisfy { $0 > 120 })
    #expect(try rgb(#require(faded), x: 320, y: 255).allSatisfy { abs($0 - 80) < 8 })
    #expect(try rgb(#require(disabled), x: 98, y: 96).allSatisfy { abs($0 - 80) < 8 })
    #expect(animatesThroughout(times, from: pillAt, to: pillAt + 1.5))
}

/// Overlay invalidations alone keep a movie's frames coming. Without them, a movie holds one frame until the
/// next state change, a gap of a second or more here. A slow encoder spaces frames further apart, but by much
/// less than this bound, so the check does not depend on the frame rate. The window counts its own ends, so
/// frames that start late or stop early fail too. Callers start the window after the encoder's warm-up.
private func animatesThroughout(_ times: [Double], from start: Double, to end: Double) -> Bool {
    let edges = [start] + times.filter { $0 > start && $0 < end } + [end]
    return edges.count > 5 && zip(edges, edges.dropFirst()).allSatisfy { $1 - $0 < 0.4 }
}

@Test(arguments: [1.0, 2.0]) func recordingAgentCursorMovesAndPressesWithoutAScreenObserver(unit: Double) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("agent-cursor.mov")
    #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
    let frames = try MetalDesktop(device: #require(MTLCreateSystemDefaultDevice()))
    desktop(width: 640, height: 360, bgra: [80, 80, 80, 0], sink: frames)
    let state = SessionOverlayState()
    state.configure(showPointerInRecordings: true, showKeyPresses: false, showAgentPointer: false, scale: unit)
    state.setDesktopSize(CGSize(width: 640, height: 360))
    state.setAgentCursorVisible(true)
    state.setAgentCursorBusy(true)
    state.moveAgentCursor(to: CGPoint(x: 80, y: 180), animated: false)
    let media = AppleCaptureMedia(overlays: state)
    let png = try media.png(frames.snapshot())
    let started = ProcessInfo.processInfo.systemUptime
    let movie = try media.movie(at: url, source: frames)
    // The movie's clock starts after `started`, 29 ms after it once on the CI runner, so a frame's time is
    // that much earlier than the test's time for the same moment. Windows that must hold the first frame
    // after an event open this long before it, while the screen still shows the state before the event.
    let lead = 0.1
    // The move starts after the encoder's warm-up, which held the second frame back 0.5 s on the CI runner.
    try await Task.sleep(for: .seconds(1))
    let moveAt = ProcessInfo.processInfo.systemUptime - started
    // Three legs, out, back and out again, each starting as the last one settles. One move spends only
    // about 0.25 s between the resting positions, which a slow encoder samples once or twice. A leg's
    // window opens while the cursor still rests at its start, so it holds the frame the move starts.
    var legs: [(start: Double, arrival: Double, outbound: Bool)] = []
    for (index, x) in [500.0, 80, 500].enumerated() {
        let start = ProcessInfo.processInfo.systemUptime - started
        let arrival = state.moveAgentCursor(to: CGPoint(x: x, y: index == 1 ? 180 : 140), animated: true)
        legs.append((start, arrival, index != 1))
        try await Task.sleep(for: .seconds(arrival + lead))
    }
    let arrivedAt = ProcessInfo.processInfo.systemUptime - started
    // Each state holds for several frame intervals of a slow encoder, so the movie records it at any frame rate.
    try await Task.sleep(for: .seconds(0.55))
    let pressAt = ProcessInfo.processInfo.systemUptime - started
    state.pressAgentCursor(depth: CursorTuning.clickDepth, animated: true)
    state.receive(.agent, .pointer(.init(x: 500, y: 140), .left))
    try await Task.sleep(for: .milliseconds(450))
    state.releaseAgentCursor()
    try await Task.sleep(for: .milliseconds(450))
    let humanAt = ProcessInfo.processInfo.systemUptime - started
    state.receive(.human, .pointer(.init(x: 200, y: 100), .left))
    // The ring stays bright enough for the check below for about 0.2 s. Record all of that time.
    try await Task.sleep(for: .milliseconds(300))
    _ = try await movie.finish().get()
    #expect(try media.png(frames.snapshot()) == png)
    #expect(state.snapshot().clicks.allSatisfy { $0.source == .human })

    let asset = AVURLAsset(url: url)
    let reader = try AVAssetReader(asset: asset)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    #expect(reader.startReading())
    var resting: CVPixelBuffer?
    var pressed: [(time: Double, buffer: CVPixelBuffer)] = []
    var human: [CVPixelBuffer] = []
    var centers: [[Double]] = legs.map { _ in [] }
    var times: [Double] = []
    func rgb(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> [Int] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytes =
            CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return [Int(bytes[2]), Int(bytes[1]), Int(bytes[0])]
    }
    while let sample = output.copyNextSampleBuffer() {
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
        times.append(time)
        if let leg = legs.firstIndex(where: { time > $0.start - lead && time < $0.start + $0.arrival }) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
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
            if pixels > 0 { centers[leg].append(sum / pixels) }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        if time > arrivedAt + 0.15 && time < pressAt { resting = buffer }
        if time > pressAt + 0.08 && time < pressAt + 0.45 { pressed.append((time - pressAt, buffer)) }
        if time > humanAt - lead && time < humanAt + 0.5 { human.append(buffer) }
    }
    #expect(animatesThroughout(times, from: moveAt, to: humanAt))
    // The cursor travels between resting centers near x 84-96 and 504-514. Frames between them are in each
    // leg's travel order. In at least one leg, two of them are more than 20 px apart and the leg covers 200 px.
    let between = zip(legs, centers).map { leg, centers in
        let inside = centers.filter { (105...500).contains($0) }
        return leg.outbound ? inside : inside.reversed()
    }
    let travel = "centers by leg: \(centers.map { $0.map(Int.init) })"
    #expect(between.allSatisfy { $0 == $0.sorted() }, "\(travel)")
    #expect(between.contains { ($0.last ?? 0) - ($0.first ?? 0) > 20 }, "\(travel)")
    #expect(centers.contains { ($0.max() ?? 0) - ($0.min() ?? 0) > 200 }, "\(travel)")
    let rest = try #require(resting)
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
    let restingArea = glyphArea(rest)
    // No agent click ring at radius 14; pressing shrinks the glyph about the same target tip. A ring would
    // stay brighter than this bound for about 0.19 s, so a frame in that time must show the pressed glyph,
    // and every pressed frame is checked.
    #expect(pressed.contains { $0.time < 0.19 && Double(glyphArea($0.buffer)) < 0.85 * Double(restingArea) })
    for (_, press) in pressed {
        #expect(rgb(press, 500 + Int(14 * unit), 140)[2] < 135)
        #expect(rgb(press, 500, 140).allSatisfy { $0 > 125 })
    }
    // The user's ring still appears, away from the agent sprite. It fades from its first frames, so the
    // frame the click wakes counts. Frames from before the click show the gray desktop at this point.
    #expect(human.contains { rgb($0, 200 + Int(14 * unit), 100)[2] > 150 })
}
