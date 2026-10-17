import Testing
import Foundation
import AVFoundation
import ImageIO
import CoreGraphics
@testable import RemoraCore

private func desktop(width: Int, height: Int, bgra: [UInt8], sink: CaptureFrameSink) {
    // Padded rows catch accidental use of tightly packed source strides.
    let stride = width * 4 + 16
    var pixels = [UInt8](repeating: 0, count: stride * height)
    for y in 0..<height {
        for x in 0..<width { pixels.replaceSubrange((y * stride + x * 4)..<(y * stride + x * 4 + 4), with: bgra) }
    }
    pixels.withUnsafeBytes {
        sink.consume(BorrowedFrame(pixels: $0.baseAddress!, width: width, height: height, stride: stride,
                                   dirtyRectangles: [.init(x: 0, y: 0, width: 1, height: 1)]))
    }
    // Destroy the borrowed storage. A later screenshot must retain the whole desktop.
    _ = pixels.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
}

@Test func screenshotRetainsFullDesktopAndWritesOpaquePNG() throws {
    let frames = CaptureFrameSink()
    desktop(width: 8, height: 6, bgra: [21, 87, 231, 0], sink: frames)
    let png = try AppleCaptureMedia().png(frames.snapshot())
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
}

@Test func hardwareMovieSurvivesResizeAndIncludesIdleTime() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("synthetic.mov")
    #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
    let frames = CaptureFrameSink()
    desktop(width: 320, height: 240, bgra: [20, 30, 240, 0], sink: frames)
    let movie = try frames.record(using: AppleCaptureMedia(), at: url)
    try await Task.sleep(for: .milliseconds(180))
    desktop(width: 160, height: 240, bgra: [30, 240, 20, 0], sink: frames)
    // Exercise latest-frame coalescing faster than the 60 fps limit.
    let green: [UInt8] = [30, 240, 20, 0]
    var burst = Array(repeating: green, count: 160 * 240).flatMap { $0 }
    for index in 0..<40 {
        burst[0] = UInt8(index)
        burst.withUnsafeBytes {
            frames.consume(BorrowedFrame(pixels: $0.baseAddress!, width: 160, height: 240, stride: 640,
                                         dirtyRectangles: [.init(x: 0, y: 0, width: 1, height: 1)]))
        }
    }
    try await Task.sleep(for: .milliseconds(520))
    frames.detachMovie()
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
}
