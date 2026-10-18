import Testing
import Foundation
import AVFoundation
import ImageIO
import CoreGraphics
import Metal
@testable import RemoraCore

private func desktop(width: Int, height: Int, bgra: [UInt8], sink: MetalDesktop) {
    // Padded rows catch accidental use of tightly packed source strides.
    let stride = width * 4 + 16
    var pixels = [UInt8](repeating: 0, count: stride * height)
    for y in 0..<height {
        for x in 0..<width { pixels.replaceSubrange((y * stride + x * 4)..<(y * stride + x * 4 + 4), with: bgra) }
    }
    _ = pixels.withUnsafeBytes {
        try! sink.ingest(BorrowedFrame(pixels: $0.baseAddress!, width: width, height: height, stride: stride,
                                   dirtyRectangles: [.init(x: 0, y: 0, width: 1, height: 1)]))
    }
    // Destroy the borrowed storage. A later screenshot must retain the whole desktop.
    _ = pixels.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
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
        let context = try #require(CGContext(data: $0.baseAddress, width: 8, height: 6, bitsPerComponent: 8,
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
        try frames.ingest(BorrowedFrame(pixels: $0.baseAddress!, width: 8, height: 6, stride: 32,
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
    #expect(await capture.stopRecording() == nil)
}

@Test func hardwareMovieSurvivesResizeAndIncludesIdleTime() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("synthetic.mov")
    #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
    let frames = try MetalDesktop(device: #require(MTLCreateSystemDefaultDevice()))
    desktop(width: 320, height: 240, bgra: [20, 30, 240, 0], sink: frames)
    let movie = try AppleCaptureMedia().movie(at: url, source: frames)
    frames.setFrameObserver { movie.submit(arrival: $0) }
    try await Task.sleep(for: .milliseconds(180))
    desktop(width: 160, height: 240, bgra: [30, 240, 20, 0], sink: frames)
    // Exercise latest-frame coalescing faster than the 60 fps limit.
    let green: [UInt8] = [30, 240, 20, 0]
    var burst = Array(repeating: green, count: 160 * 240).flatMap { $0 }
    for offset in stride(from: 0, to: 160 * 80 * 4, by: 4) {
        burst.replaceSubrange(offset..<offset + 4, with: [230, 30, 20, 0])
    }
    for index in 0..<40 {
        burst[0] = UInt8(index)
        _ = burst.withUnsafeBytes {
            try! frames.ingest(BorrowedFrame(pixels: $0.baseAddress!, width: 160, height: 240, stride: 640,
                                         dirtyRectangles: [.init(x: 0, y: 0, width: index == 0 ? 160 : 1, height: index == 0 ? 80 : 1)]))
        }
    }
    try await Task.sleep(for: .milliseconds(520))
    frames.setFrameObserver(nil)
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
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
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
    frames.setFrameObserver { movie.submit(arrival: $0) }
    for change in 0..<changes {
        try await Task.sleep(for: .milliseconds(100))
        desktop(width: 320, height: 240, bgra: [UInt8(40 + change), 30, 240, 0], sink: frames)
    }
    // No more source frames. Exceed the encoder's default last-sample duration.
    try await Task.sleep(for: .milliseconds(1350))
    frames.setFrameObserver(nil)
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
           let duration = movieMediaDuration(data, range: offset + 8..<offset + size) { return duration }
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
