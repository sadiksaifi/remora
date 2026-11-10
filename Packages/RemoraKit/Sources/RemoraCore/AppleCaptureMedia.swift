import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox
import Metal

public struct ScreenshotDestination: CaptureDestination {
    private let folder: @Sendable () -> URL?

    /// `folder` runs for each capture and returns nil to use the macOS screenshot location.
    public init(folder: @escaping @Sendable () -> URL? = { nil }) {
        self.folder = folder
    }

    /// The folder macOS saves screenshots to: Desktop unless the user changed it.
    public static var screenshotLocation: URL {
        let configured = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        return configured.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop", directoryHint: .isDirectory)
    }

    public static func reserve(at url: URL) throws -> URL {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        if fd < 0, errno == EEXIST { throw CaptureFailure.destinationExists(url.path) }
        guard fd >= 0 else { throw CaptureFailure.file("\(url.path): \(String(cString: strerror(errno)))") }
        Darwin.close(fd)
        return url
    }

    public func reserve(connectionName: String, extension suffix: String) throws -> URL {
        let directory = folder() ?? Self.screenshotLocation
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = connectionName.components(separatedBy: CharacterSet(charactersIn: "/:\0\n\r")).joined(separator: "-")
        let base = "Remora - \(String(name.prefix(160))) - \(formatter.string(from: Date()))"
        for index in 0..<10_000 {
            let url = directory.appendingPathComponent(base + (index == 0 ? "" : " (\(index + 1))") + "." + suffix)
            // O_EXCL reserves without a check-then-create race, including across processes.
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            if fd >= 0 { Darwin.close(fd); return url }
            if errno != EEXIST { throw CaptureFailure.file(String(cString: strerror(errno))) }
        }
        throw CaptureFailure.file("No unused filename is available.")
    }
}

public struct AppleCaptureMedia: CaptureMedia {
    private let overlays: SessionOverlayState?

    public init(overlays: SessionOverlayState? = nil) { self.overlays = overlays }

    public func png(_ frame: CaptureFrame) throws -> Data {
        try png(frame, geometry: ScreenshotGeometry(desktop: frame.size))
    }

    public func png(_ frame: CaptureFrame, geometry: ScreenshotGeometry) throws -> Data {
        guard let desktop = Self.image(frame),
              let cropped = desktop.cropping(to: CGRect(x: geometry.region.x, y: geometry.region.y,
                    width: geometry.region.width, height: geometry.region.height)) else {
            throw CaptureFailure.image("Could not crop the image.")
        }
        let image: CGImage
        if geometry.encoded.width == cropped.width, geometry.encoded.height == cropped.height { image = cropped }
        else {
            guard let context = CGContext(data: nil, width: geometry.encoded.width, height: geometry.encoded.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CaptureFailure.image("Could not scale the image.") }
            context.interpolationQuality = .high
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: geometry.encoded.width, height: geometry.encoded.height))
            guard let scaled = context.makeImage() else { throw CaptureFailure.image("Could not scale the image.") }
            image = scaled
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CaptureFailure.image("Could not create the image.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureFailure.image("PNG encoding failed.") }
        return data as Data
    }

    static func image(_ frame: CaptureFrame) -> CGImage? {
        guard let provider = CGDataProvider(data: frame.pixels as CFData) else { return nil }
        return CGImage(width: frame.size.width, height: frame.size.height, bitsPerComponent: 8,
                       bitsPerPixel: 32, bytesPerRow: frame.size.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)],
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public func movie(at url: URL, source: any CaptureSource) throws -> any CaptureMovie {
        guard let source = source as? MetalDesktop else { throw CaptureFailure.recording("A Metal desktop is required.") }
        let workingURL = url.deletingLastPathComponent().appendingPathComponent(".Remora-\(UUID().uuidString).partial.mov")
        do { return try AppleCaptureMovie(url: url, workingURL: workingURL, source: source, overlays: overlays) }
        catch {
            do {
                if FileManager.default.fileExists(atPath: workingURL.path) { try FileManager.default.removeItem(at: workingURL) }
            } catch {
                throw CaptureFailure.file("Partial movie remains at \(workingURL.path): \(error.localizedDescription)")
            }
            throw error
        }
    }
}

/// After construction, media operations run on queue. The mailbox holds one arrival time.
/// @unchecked covers queue-confined framework objects; mailbox and outcome use lock.
final class AppleCaptureMovie: CaptureMovie, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.sadiksaifi.Remora.capture", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: TimeInterval?
    private var scheduled = false
    private var accepting = true
    private var outcome: Result<URL, CaptureFailure>?
    private var waiters: [CheckedContinuation<Result<URL, CaptureFailure>, Never>] = []
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var context: CIContext?
    private let source: MetalDesktop
    private let overlays: SessionOverlayState?
    private var overlayObserver: UUID?
    private let overlayDrawing = SessionOverlayDrawing()
    private let textureCache: CVMetalTextureCache
    private let url: URL
    private let workingURL: URL
    private let size: DesktopSize
    private let origin: TimeInterval
    private var lastPTS: TimeInterval = -1
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastAppend: TimeInterval = 0
    private var lastArrival: TimeInterval = -.infinity
    private var finishTimer: DispatchSourceTimer?
    private var finishing = false
    private var finishingWriter = false
    private var stopTime: TimeInterval = 0
    private var finishDeadline: TimeInterval = 0

    let failures: AsyncStream<CaptureFailure>
    private let failureContinuation: AsyncStream<CaptureFailure>.Continuation
    private var writerObservation: NSKeyValueObservation?

    init(url: URL, workingURL: URL, source: MetalDesktop, overlays: SessionOverlayState?) throws {
        self.overlays = overlays
        self.url = url
        self.workingURL = workingURL
        (failures, failureContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.source = source
        guard let size = source.size else { throw CaptureFailure.noFrame }
        self.size = size
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, source.device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw CaptureFailure.recording("No Metal pixel buffer texture cache.") }
        textureCache = cache
        origin = ProcessInfo.processInfo.systemUptime
        // Keep the filename reservation until the finished movie atomically replaces it.
        writer = try AVAssetWriter(outputURL: workingURL, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
            // Fail without a hardware encoder rather than fall back to software encoding.
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(40_000_000, max(2_000_000, size.width * size.height * 4)),
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw CaptureFailure.recording("Hardware HEVC settings are unavailable.") }
        writer.add(input)
        guard writer.startWriting() else { throw CaptureFailure.recording(writer.error?.localizedDescription ?? "Could not start HEVC encoder.") }
        writer.startSession(atSourceTime: .zero)
        writerObservation = writer.observe(\.status, options: [.new]) { [weak self] writer, _ in
            guard writer.status == .failed, let self else { return }
            self.queue.async { self.fail(.recording(self.writer.error?.localizedDescription ?? "Encoder failed.")) }
        }
        overlayObserver = overlays?.addObserver { [weak self] in self?.submit(arrival: $0) }
    }

    deinit { stopObservingOverlays() }

    func submit(arrival: TimeInterval) {
        let wake = lock.withLock {
            guard accepting, outcome == nil else { return false }
            pending = max(pending ?? arrival, arrival)
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if wake { queue.async { self.drain() } }
    }

    func finish() async -> Result<URL, CaptureFailure> {
        let stoppedAt = ProcessInfo.processInfo.systemUptime - origin
        return await withCheckedContinuation { continuation in
            let begin = lock.withLock {
                if let outcome { continuation.resume(returning: outcome); return false }
                waiters.append(continuation)
                guard accepting else { return false }
                accepting = false
                return true
            }
            if begin {
                stopObservingOverlays()
                queue.async {
                    self.finishing = true
                    self.stopTime = stoppedAt
                    self.finishDeadline = ProcessInfo.processInfo.systemUptime + 5
                    self.drain()
                }
                queue.async { [self] in
                    guard self.lock.withLock({ self.outcome == nil }) else { return }
                    let timer = DispatchSource.makeTimerSource(queue: self.queue)
                    timer.schedule(deadline: .now() + 8)
                    timer.setEventHandler { [weak self] in self?.fail(.timedOut) }
                    self.finishTimer = timer
                    timer.resume()
                }
            }
        }
    }

    private func drain() {
        guard !finishingWriter, lock.withLock({ outcome == nil }) else { return }
        if writer.status == .failed { fail(.recording(writer.error?.localizedDescription ?? "Encoder failed.")); return }
        let now = ProcessInfo.processInfo.systemUptime
        if finishing && now >= finishDeadline { fail(.timedOut); return }
        if lock.withLock({ pending != nil }), input.isReadyForMoreMediaData, now - lastAppend >= 1.0 / 60 {
            let selected = lock.withLock { () -> TimeInterval? in
                let arrival = pending
                pending = nil
                return arrival
            }
            if let selected, selected > lastArrival {
                do {
                    if let arrival = try append(at: selected) {
                        lastArrival = arrival
                        // Preserve the pacing clock across small scheduling delays, without replaying idle time.
                        lastAppend = now - lastAppend >= 2.0 / 60 ? now : lastAppend + 1.0 / 60
                    } else {
                        lastAppend = ProcessInfo.processInfo.systemUptime
                        lock.withLock { if pending == nil { pending = selected } }
                    }
                } catch { fail(error as? CaptureFailure ?? .recording(error.localizedDescription)); return }
            }
        }
        let hasPending = lock.withLock { () -> Bool in
            if pending != nil { return true }
            scheduled = false
            return false
        }
        if finishing && !hasPending {
            let endTime = CMTime(seconds: max(stopTime, lastPTS + 1.0 / 60), preferredTimescale: 60_000)
            // endSession alone creates an extended edit, but leaves the encoded media short.
            // Reuse the last immutable pool buffer so its preceding sample holds through Stop.
            if let lastPixelBuffer, endTime.seconds > lastPTS + 1.0 / 60 {
                guard input.isReadyForMoreMediaData else {
                    queue.asyncAfter(deadline: .now() + 1.0 / 60) { self.drain() }
                    return
                }
                guard adaptor.append(lastPixelBuffer, withPresentationTime: endTime) else {
                    fail(.recording(writer.error?.localizedDescription ?? "Final frame append failed."))
                    return
                }
            }
            finishingWriter = true
            writer.endSession(atSourceTime: endTime)
            input.markAsFinished()
            writer.finishWriting { self.queue.async {
                if self.writer.status == .completed {
                    if rename(self.workingURL.path, self.url.path) == 0 { self.complete(.success(self.url)) }
                    else { self.fail(.file(String(cString: strerror(errno)))) }
                } else { self.fail(.recording(self.writer.error?.localizedDescription ?? "Could not finish the movie.")) }
            } }
        } else if hasPending {
            let delay = input.isReadyForMoreMediaData
                ? max(0.0001, lastAppend + 1.0 / 60 - ProcessInfo.processInfo.systemUptime) : 1.0 / 60
            queue.asyncAfter(deadline: .now() + delay) { self.drain() }
        }
    }

    private func append(at arrival: TimeInterval) throws -> TimeInterval? {
        guard let pool = adaptor.pixelBufferPool else { throw CaptureFailure.recording("No pixel buffer pool.") }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary, &pixelBuffer)
        if status == kCVReturnWouldExceedAllocationThreshold {
            CVMetalTextureCacheFlush(textureCache, 0)
            return nil
        }
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw CaptureFailure.recording("Pixel buffer allocation failed (\(status)).")
        }
        var cvTexture: CVMetalTexture?
        let textureStatus = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer,
            [kCVMetalTextureUsage as String: MTLTextureUsage.shaderWrite.rawValue | MTLTextureUsage.shaderRead.rawValue] as CFDictionary,
            .bgra8Unorm, size.width, size.height, 0, &cvTexture)
        guard textureStatus == kCVReturnSuccess, let cvTexture, let destination = CVMetalTextureGetTexture(cvTexture) else {
            throw CaptureFailure.recording("Could not map encoder pixel buffer into Metal (\(textureStatus)).")
        }
        let submission = try source.submit { texture, command in
            let desktopSize = CGSize(width: texture.width, height: texture.height)
            let snapshot = overlays?.snapshot(at: arrival)
            let sprites = snapshot.map { overlayDrawing.sprites($0, recording: true) } ?? []
            let glass = snapshot.flatMap { overlayDrawing.keyPress($0, desktop: desktopSize) }
            if texture.width == size.width && texture.height == size.height && sprites.isEmpty && glass == nil {
                guard let blit = command.makeBlitCommandEncoder() else { throw CaptureFailure.recording("No encoder blit command.") }
                blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                          sourceSize: MTLSize(width: size.width, height: size.height, depth: 1),
                          to: destination, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
                blit.endEncoding()
            } else {
                if context == nil { context = CIContext(mtlDevice: source.device, options: [.cacheIntermediates: false]) }
                // The remote desktop's alpha byte is undefined. A same-format view forces opaque sampling
                // without a conversion pass or modifying the renderer's texture.
                guard let opaque = texture.makeTextureView(pixelFormat: .bgra8Unorm, textureType: .type2D,
                    levels: 0..<1, slices: 0..<1,
                    swizzle: MTLTextureSwizzleChannels(red: .red, green: .green, blue: .blue, alpha: .one)),
                    let image = CIImage(mtlTexture: opaque, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]) else {
                    throw CaptureFailure.recording("Invalid desktop texture.")
                }
                var decorated = glass.map { Self.composite($0, over: image) } ?? image
                for sprite in sprites {
                    let rect = sprite.rect
                    var overlay = CIImage(cgImage: sprite.image)
                        .transformed(by: CGAffineTransform(scaleX: rect.width / CGFloat(sprite.image.width),
                                                          y: -rect.height / CGFloat(sprite.image.height)))
                        .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.maxY))
                        .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: sprite.opacity)])
                    if sprite.blurRadius > 0 {
                        overlay = overlay.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sprite.blurRadius])
                    }
                    decorated = overlay.composited(over: decorated)
                }
                let scale = min(Double(size.width) / Double(texture.width), Double(size.height) / Double(texture.height))
                let fitted = decorated.cropped(to: image.extent)
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .transformed(by: CGAffineTransform(translationX: (Double(size.width) - Double(texture.width) * scale) / 2,
                                                      y: (Double(size.height) - Double(texture.height) * scale) / 2))
                let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
                let composite = fitted.composited(over: CIImage(color: .black).cropped(to: bounds))
                context!.render(composite, to: destination, commandBuffer: command, bounds: bounds,
                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
        }
        // Keep both Core Video wrappers alive through the GPU copy. Never wait on the session thread.
        withExtendedLifetime(cvTexture) { submission.command.waitUntilCompleted() }
        guard submission.command.status == .completed else {
            throw CaptureFailure.recording(submission.command.error?.localizedDescription ?? "Encoder GPU copy failed.")
        }
        let captureTime = max(arrival, submission.arrival)
        let timestamp = lastPTS < 0 ? 0 : max(lastPTS + 1.0 / 60, captureTime - origin)
        guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(seconds: timestamp, preferredTimescale: 60_000)) else {
            throw CaptureFailure.recording(writer.error?.localizedDescription ?? "Frame append failed.")
        }
        lastPTS = timestamp
        lastPixelBuffer = pixelBuffer
        return captureTime
    }

    /// The closest rendition of Liquid Glass a frame can hold: the desktop behind the capsule blurred,
    /// saturated and tinted for the appearance, under the drawn shadow, rim, keycaps and text.
    /// Image coordinates here are desktop pixels from the top left, like sprite rects.
    private static func composite(_ glass: SessionOverlayDrawing.Glass, over image: CIImage) -> CIImage {
        let frame = glass.frame
        let backdrop = image.clampedToExtent().applyingGaussianBlur(sigma: frame.height / 5).cropped(to: frame)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: glass.dark ? 3 : 1.4])
        // Dark glass flattens the backdrop toward a dark gray and keeps its hue, matched to screen captures.
        let tint = CIImage(color: glass.dark ? CIColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 0.9) : CIColor(red: 1, green: 1, blue: 1, alpha: 0.45))
            .cropped(to: frame)
        let fade = CIVector(x: 0, y: 0, z: 0, w: glass.opacity)
        let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: frame),
            "inputRadius": frame.height / 2, "inputColor": CIColor(red: 1, green: 1, blue: 1, alpha: glass.opacity)])!.outputImage!
        let rect = glass.imageRect
        let chrome = CIImage(cgImage: glass.image)
            .transformed(by: CGAffineTransform(scaleX: rect.width / CGFloat(glass.image.width), y: -rect.height / CGFloat(glass.image.height)))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.maxY))
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": fade])
        // Masking keeps the glass within its frame, so no extra pass touches the rest of the desktop.
        return chrome.composited(over: tint.composited(over: backdrop)
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])).composited(over: image)
    }

    private func stopObservingOverlays() {
        let observer = lock.withLock {
            let observer = overlayObserver
            overlayObserver = nil
            return observer
        }
        if let observer { overlays?.removeObserver(observer) }
    }

    private func fail(_ error: CaptureFailure) {
        guard lock.withLock({ outcome == nil }) else { return }
        if writer.status == .writing { writer.cancelWriting() }
        var failure = error
        for file in [workingURL, url] {
            do { if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) } }
            catch { failure = .file("\(failure.localizedDescription) Capture file remains at \(file.path): \(error.localizedDescription)") }
        }
        complete(.failure(failure))
    }

    private func complete(_ result: Result<URL, CaptureFailure>) {
        stopObservingOverlays()
        lastPixelBuffer = nil
        finishTimer?.cancel()
        finishTimer = nil
        writerObservation?.invalidate()
        writerObservation = nil
        let callbacks = lock.withLock { () -> [CheckedContinuation<Result<URL, CaptureFailure>, Never>] in
            guard outcome == nil else { return [] }
            outcome = result
            accepting = false
            pending = nil
            let callbacks = waiters
            waiters = []
            return callbacks
        }
        if case .failure(let failure) = result { failureContinuation.yield(failure) }
        failureContinuation.finish()
        callbacks.forEach { $0.resume(returning: result) }
    }
}
