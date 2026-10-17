import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox
import Metal

public struct ScreenshotDestination: CaptureDestination {
    public init() {}

    public func reserve(connectionName: String, extension suffix: String) throws -> URL {
        let manager = FileManager.default
        let configured = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        let directory = configured.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? manager.homeDirectoryForCurrentUser.appending(path: "Desktop", directoryHint: .isDirectory)
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
    public init() {}

    public func png(_ frame: CaptureFrame) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil),
              let image = Self.image(frame) else { throw CaptureFailure.image("Could not create the image.") }
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
        do { return try AppleCaptureMovie(url: url, workingURL: workingURL, source: source) }
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

/// After construction, media operations run on queue. The mailbox is one owned frame.
/// @unchecked covers queue-confined framework objects; mailbox and outcome use lock.
final class AppleCaptureMovie: CaptureMovie, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.sadiksaifi.Remora.capture", qos: .utility)
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
    private let textureCache: CVMetalTextureCache
    private let url: URL
    private let workingURL: URL
    private let size: DesktopSize
    private let origin: TimeInterval
    private var lastPTS: TimeInterval = -1
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

    init(url: URL, workingURL: URL, source: MetalDesktop) throws {
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
    }

    func submit(arrival: TimeInterval) {
        let wake = lock.withLock {
            guard accepting, outcome == nil else { return false }
            pending = arrival
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if wake { queue.async { self.drain() } }
    }

    func finish() async -> Result<URL, CaptureFailure> {
        await withCheckedContinuation { continuation in
            let begin = lock.withLock {
                if let outcome { continuation.resume(returning: outcome); return false }
                waiters.append(continuation)
                guard accepting else { return false }
                accepting = false
                return true
            }
            if begin {
                queue.async {
                    self.finishing = true
                    self.stopTime = ProcessInfo.processInfo.systemUptime - self.origin
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
                    if let arrival = try append() {
                        lastArrival = arrival
                        lastAppend = now
                    } else {
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
            finishingWriter = true
            writer.endSession(atSourceTime: CMTime(seconds: max(stopTime, lastPTS + 1.0 / 60), preferredTimescale: 60_000))
            input.markAsFinished()
            writer.finishWriting { self.queue.async {
                if self.writer.status == .completed {
                    if rename(self.workingURL.path, self.url.path) == 0 { self.complete(.success(self.url)) }
                    else { self.fail(.file(String(cString: strerror(errno)))) }
                } else { self.fail(.recording(self.writer.error?.localizedDescription ?? "Could not finish the movie.")) }
            } }
        } else if hasPending {
            queue.asyncAfter(deadline: .now() + 1.0 / 60) { self.drain() }
        }
    }

    private func append() throws -> TimeInterval? {
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
            if texture.width == size.width && texture.height == size.height {
                guard let blit = command.makeBlitCommandEncoder() else { throw CaptureFailure.recording("No encoder blit command.") }
                blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                          sourceSize: MTLSize(width: size.width, height: size.height, depth: 1),
                          to: destination, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
                blit.endEncoding()
            } else {
                if context == nil { context = CIContext(mtlDevice: source.device, options: [.cacheIntermediates: false]) }
                // FreeRDP's alpha byte is undefined. A same-format view forces opaque sampling
                // without a conversion pass or modifying the renderer's texture.
                guard let opaque = texture.makeTextureView(pixelFormat: .bgra8Unorm, textureType: .type2D,
                    levels: 0..<1, slices: 0..<1,
                    swizzle: MTLTextureSwizzleChannels(red: .red, green: .green, blue: .blue, alpha: .one)),
                    let image = CIImage(mtlTexture: opaque, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]) else {
                    throw CaptureFailure.recording("Invalid desktop texture.")
                }
                let scale = min(Double(size.width) / Double(texture.width), Double(size.height) / Double(texture.height))
                let fitted = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
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
        let timestamp = lastPTS < 0 ? 0 : max(lastPTS + 1.0 / 60, submission.arrival - origin)
        guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(seconds: timestamp, preferredTimescale: 60_000)) else {
            throw CaptureFailure.recording(writer.error?.localizedDescription ?? "Frame append failed.")
        }
        lastPTS = timestamp
        return submission.arrival
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
