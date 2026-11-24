import Foundation
import Observation

public enum CaptureFailure: Error, Sendable, Equatable, LocalizedError {
    case noFrame
    case busy
    case image(String)
    case recording(String)
    case file(String)
    case destinationExists(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .noFrame: "The session has not received a desktop frame."
        case .busy: "A recording is already active or finishing."
        case .image(let message): "Screenshot failed: \(message)"
        case .recording(let message): "Recording failed: \(message)"
        case .file(let message): "Capture file failed: \(message)"
        case .destinationExists(let path): "A file already exists at \(path)."
        case .timedOut: "The recording could not finish before the timeout."
        }
    }
}

/// Owned, tightly packed BGRA pixels. Alpha is ignored by capture adapters.
public struct CaptureFrame: Sendable {
    public let pixels: Data
    public let size: DesktopSize
    public let arrival: TimeInterval
    public let revision: Int

    public init(copying frame: BorrowedFrame, arrival: TimeInterval = ProcessInfo.processInfo.systemUptime, revision: Int = 0) {
        size = DesktopSize(width: frame.width, height: frame.height)
        self.arrival = arrival
        self.revision = revision
        var data = Data(count: frame.width * frame.height * 4)
        data.withUnsafeMutableBytes { destination in
            for row in 0..<frame.height {
                destination.baseAddress!.advanced(by: row * frame.width * 4)
                    .copyMemory(from: frame.pixels.advanced(by: row * frame.stride), byteCount: frame.width * 4)
            }
        }
        pixels = data
    }

    /// True when the frame is black all over, like the frames a Windows server sends while it attaches a session.
    /// Checks a grid of pixels, and allows the few levels of noise a video codec leaves in black.
    public var isBlank: Bool {
        pixels.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for y in stride(from: 0, to: size.height, by: max(1, size.height / 64)) {
                for x in stride(from: 0, to: size.width, by: max(1, size.width / 64)) {
                    let pixel = (y * size.width + x) * 4
                    if bytes[pixel] > 8 || bytes[pixel + 1] > 8 || bytes[pixel + 2] > 8 { return false }
                }
            }
            return true
        }
    }
}

/// The renderer or a future protocol adapter supplies a complete desktop only when requested.
public protocol CaptureSource: AnyObject, Sendable {
    var size: DesktopSize? { get }
    func snapshot() throws -> CaptureFrame
    /// Installing an observer also announces the current frame, if available.
    func addFrameObserver(_ observer: @escaping @Sendable (TimeInterval) -> Void) -> UUID
    func removeFrameObserver(_ id: UUID)
}

public protocol CaptureMovie: AnyObject, Sendable {
    var failures: AsyncStream<CaptureFailure> { get }
    func submit(arrival: TimeInterval)
    func finish() async -> Result<URL, CaptureFailure>
}

public protocol CaptureMedia: Sendable {
    func png(_ frame: CaptureFrame) throws -> Data
    func png(_ frame: CaptureFrame, geometry: ScreenshotGeometry) throws -> Data
    func movie(at url: URL, source: any CaptureSource) throws -> any CaptureMovie
}

public protocol CaptureDestination: Sendable {
    func reserve(connectionName: String, extension suffix: String) throws -> URL
}

public enum RecordingState: Sendable, Equatable {
    case idle
    /// Monotonic start time. Use elapsed(at:) to display a live elapsed time without polling the encoder.
    case recording(startedAt: TimeInterval)
    case finishing
    case failed(CaptureFailure)

    /// True while the session records or finishes writing a recording.
    public var isWriting: Bool {
        switch self {
        case .recording, .finishing: true
        case .idle, .failed: false
        }
    }

    public func elapsed(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval? {
        guard case .recording(let start) = self else { return nil }
        return max(0, uptime - start)
    }
}

@MainActor @Observable
public final class SessionCapture {
    @ObservationIgnored private var source: (any CaptureSource)?
    @ObservationIgnored private var recordingObserver: UUID?
    @ObservationIgnored private var recordingSource: (any CaptureSource)?
    public private(set) var recordingState: RecordingState = .idle {
        didSet { onRecordingStateChange?() }
    }
    public private(set) var lastSavedURL: URL?
    public private(set) var recordingURL: URL?
    public private(set) var lastRecordingResult: Result<URL, CaptureFailure>?
    @ObservationIgnored public var onRecordingStateChange: (() -> Void)?
    @ObservationIgnored public var onRecordingActivityChange: ((Bool) -> Void)?
    @ObservationIgnored private let media: any CaptureMedia
    @ObservationIgnored private let destination: any CaptureDestination
    @ObservationIgnored private var movie: (any CaptureMovie)?
    @ObservationIgnored private var finishTask: Task<Result<URL, CaptureFailure>, Never>?
    @ObservationIgnored private var monitor: Task<Void, Never>?

    public init(media: any CaptureMedia, destination: any CaptureDestination) {
        self.media = media
        self.destination = destination
    }

    isolated deinit {
        monitor?.cancel()
        if let recordingObserver { recordingSource?.removeFrameObserver(recordingObserver) }
        if let movie { Task { _ = await movie.finish() } }
    }

    /// The session attaches its renderer and retires it when the session ends.
    public func setSource(_ source: (any CaptureSource)?) {
        self.source = source
    }

    /// Encodes off the main actor. The UI can place this PNG on its platform clipboard.
    public func screenshotPNG() async throws -> Data {
        guard let source else { throw CaptureFailure.noFrame }
        let media = media
        return try await Task.detached { try media.png(source.snapshot()) }.value
    }

    /// Pixels, geometry and revision all come from the same readback.
    public func screenshot(region: ScreenshotRegion? = nil, maxSize: DesktopSize? = nil) async throws -> (Data, ScreenshotGeometry, Int) {
        guard let source else { throw CaptureFailure.noFrame }
        let media = media
        return try await Task.detached {
            let frame = try source.snapshot()
            let geometry = try ScreenshotGeometry(desktop: frame.size, region: region, maxSize: maxSize)
            return (try media.png(frame, geometry: geometry), geometry, frame.revision)
        }.value
    }

    @discardableResult
    public func saveScreenshot(connectionName: String) async throws -> URL {
        let png = try await screenshotPNG()
        return try await saveScreenshot(png, connectionName: connectionName)
    }

    /// File captures share reservation and cleanup with the session's Screenshot action.
    public func saveScreenshot(_ png: Data, connectionName: String, output: URL? = nil) async throws -> URL {
        let destination = destination
        let url = try await Task.detached {
            let url = try output.map(ScreenshotDestination.reserve(at:)) ?? destination.reserve(connectionName: connectionName, extension: "png")
            do {
                try png.write(to: url)
                return url
            } catch {
                var failure = CaptureFailure.file(error.localizedDescription)
                do { try FileManager.default.removeItem(at: url) } catch {
                    failure = .file("\(failure.localizedDescription) Capture file remains at \(url.path): \(error.localizedDescription)")
                }
                throw failure
            }
        }.value
        lastSavedURL = url
        return url
    }

    public func startRecording(connectionName: String, output: URL? = nil) throws {
        guard movie == nil, finishTask == nil else { throw CaptureFailure.busy }
        guard let source, source.size != nil else { throw CaptureFailure.noFrame }
        let url = try output.map(ScreenshotDestination.reserve(at:)) ?? destination.reserve(connectionName: connectionName, extension: "mov")
        lastRecordingResult = nil
        do {
            let startedAt = ProcessInfo.processInfo.systemUptime
            let movie = try media.movie(at: url, source: source)
            recordingSource = source
            recordingObserver = source.addFrameObserver { movie.submit(arrival: $0) }
            self.movie = movie
            recordingURL = url
            recordingState = .recording(startedAt: startedAt)
            onRecordingActivityChange?(true)
            monitor = Task { [weak self] in
                for await _ in movie.failures {
                    guard !Task.isCancelled else { return }
                    _ = await self?.stopRecording()
                }
            }
        } catch {
            var failure = error as? CaptureFailure ?? .recording(error.localizedDescription)
            do { try FileManager.default.removeItem(at: url) } catch {
                failure = .file("\(failure.localizedDescription) Capture file remains at \(url.path): \(error.localizedDescription)")
            }
            lastRecordingResult = .failure(failure)
            recordingState = .failed(failure)
            throw failure
        }
    }

    /// Idempotent. Concurrent stop, close and quit callers share the same finish operation.
    @discardableResult
    public func stopRecording() async -> Result<URL, CaptureFailure>? {
        if let finishTask { return await finishTask.value }
        guard let movie else { return lastRecordingResult }
        if let recordingObserver { recordingSource?.removeFrameObserver(recordingObserver) }
        recordingSource = nil
        recordingObserver = nil
        self.movie = nil
        monitor?.cancel()
        monitor = nil
        recordingState = .finishing
        onRecordingActivityChange?(false)
        let task = Task {
            let result = await movie.finish()
            // Publish completion before any concurrent stop caller resumes.
            finishTask = nil
            recordingURL = nil
            lastRecordingResult = result
            switch result {
            case .success(let url):
                lastSavedURL = url
                recordingState = .idle
            case .failure(let failure): recordingState = .failed(failure)
            }
            return result
        }
        finishTask = task
        return await task.value
    }
}
