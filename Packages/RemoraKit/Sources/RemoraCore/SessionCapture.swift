import Foundation
import Observation

public enum CaptureFailure: Error, Sendable, Equatable, LocalizedError {
    case noFrame
    case busy
    case image(String)
    case recording(String)
    case file(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .noFrame: "The session has not received a desktop frame."
        case .busy: "A recording is already active or finishing."
        case .image(let message): "Screenshot failed: \(message)"
        case .recording(let message): "Recording failed: \(message)"
        case .file(let message): "Capture file failed: \(message)"
        case .timedOut: "The recording could not finish before the timeout."
        }
    }
}

/// Owned, tightly packed BGRA pixels. Alpha is ignored by capture adapters.
public struct CaptureFrame: Sendable {
    public let pixels: Data
    public let size: DesktopSize
    public let arrival: TimeInterval

    public init(copying frame: BorrowedFrame, arrival: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        size = DesktopSize(width: frame.width, height: frame.height)
        self.arrival = arrival
        var data = Data(count: frame.width * frame.height * 4)
        data.withUnsafeMutableBytes { destination in
            for row in 0..<frame.height {
                destination.baseAddress!.advanced(by: row * frame.width * 4)
                    .copyMemory(from: frame.pixels.advanced(by: row * frame.stride), byteCount: frame.width * 4)
            }
        }
        pixels = data
    }
}

public protocol CaptureMovie: AnyObject, Sendable {
    var failures: AsyncStream<CaptureFailure> { get }
    func submit(_ frame: CaptureFrame)
    func finish() async -> Result<URL, CaptureFailure>
}

/// Platform image encoding and movie construction. The caller owns destination policy.
public protocol CaptureMedia: Sendable {
    func png(_ frame: CaptureFrame) throws -> Data
    func movie(at url: URL, initialFrame: CaptureFrame) throws -> any CaptureMovie
}

public protocol CaptureDestination: Sendable {
    /// Reserves a unique filename. The movie adapter may replace this empty reservation.
    func reserve(connectionName: String, extension suffix: String) throws -> URL
}

/// One complete desktop, independent of renderer damage and tab visibility.
/// The lock never spans encoding or file I/O. No borrowed pointer escapes consume.
public final class CaptureFrameSink: FrameSink, Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var generation: UInt64 = 0
    private nonisolated(unsafe) var latest: CaptureFrame?
    private nonisolated(unsafe) var movie: (any CaptureMovie)?

    public init() {}

    public func consume(_ frame: BorrowedFrame) { consume(frame, generation: nil) }

    /// A session attempt gets its own source. clear() retires it before another attempt starts.
    public func makeSource() -> any FrameSink {
        lock.withLock { Source(owner: self, generation: generation) }
    }

    private struct Source: FrameSink {
        let owner: CaptureFrameSink
        let generation: UInt64
        func consume(_ frame: BorrowedFrame) { owner.consume(frame, generation: generation) }
    }

    private func consume(_ frame: BorrowedFrame, generation: UInt64?) {
        guard frame.width > 0, frame.height > 0, frame.stride >= frame.width * 4 else { return }
        // Serialize arrivals as well as copies if a backend delivers from multiple threads.
        lock.withLock {
            guard generation == nil || generation == self.generation else { return }
            let copy = CaptureFrame(copying: frame)
            latest = copy
            movie?.submit(copy)
        }
    }

    public func snapshot() throws -> CaptureFrame {
        try lock.withLock {
            guard let latest else { throw CaptureFailure.noFrame }
            return latest
        }
    }

    func record(using media: any CaptureMedia, at url: URL) throws -> any CaptureMovie {
        let initial = try snapshot()
        let movie = try media.movie(at: url, initialFrame: initial)
        lock.withLock {
            self.movie = movie
            if let latest { movie.submit(latest) }
        }
        return movie
    }

    func detachMovie() { lock.withLock { movie = nil } }
    public func clear() { lock.withLock { latest = nil; generation &+= 1 } }
}

public enum RecordingState: Sendable, Equatable {
    case idle
    /// Monotonic start time. Use elapsed(at:) to display a live elapsed time without polling the encoder.
    case recording(startedAt: TimeInterval)
    case finishing
    case failed(CaptureFailure)

    public func elapsed(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval? {
        guard case .recording(let start) = self else { return nil }
        return max(0, uptime - start)
    }
}

@MainActor @Observable
public final class SessionCapture {
    public let frames: CaptureFrameSink
    public private(set) var recordingState: RecordingState = .idle
    public private(set) var lastSavedURL: URL?
    public private(set) var recordingURL: URL?
    @ObservationIgnored public var onRecordingActivityChange: ((Bool) -> Void)?
    @ObservationIgnored private let media: any CaptureMedia
    @ObservationIgnored private let destination: any CaptureDestination
    @ObservationIgnored private var movie: (any CaptureMovie)?
    @ObservationIgnored private var finishTask: Task<Result<URL, CaptureFailure>, Never>?
    @ObservationIgnored private var monitor: Task<Void, Never>?

    public init(media: any CaptureMedia, destination: any CaptureDestination, frames: CaptureFrameSink = .init()) {
        self.media = media
        self.destination = destination
        self.frames = frames
    }

    isolated deinit {
        monitor?.cancel()
        frames.detachMovie()
        if let movie { Task { _ = await movie.finish() } }
    }

    /// Encodes off the main actor. The UI can place this PNG on its platform clipboard.
    public func screenshotPNG() async throws -> Data {
        let frame = try frames.snapshot()
        let media = media
        return try await Task.detached { try media.png(frame) }.value
    }

    @discardableResult
    public func saveScreenshot(connectionName: String) async throws -> URL {
        let png = try await screenshotPNG()
        let destination = destination
        let url = try await Task.detached {
            let url = try destination.reserve(connectionName: connectionName, extension: "png")
            do { try png.write(to: url); return url }
            catch {
                var failure = CaptureFailure.file(error.localizedDescription)
                do { try FileManager.default.removeItem(at: url) }
                catch { failure = .file("\(failure.localizedDescription) Capture file remains at \(url.path): \(error.localizedDescription)") }
                throw failure
            }
        }.value
        lastSavedURL = url
        return url
    }

    public func startRecording(connectionName: String) throws {
        guard movie == nil, finishTask == nil else { throw CaptureFailure.busy }
        _ = try frames.snapshot()
        let url = try destination.reserve(connectionName: connectionName, extension: "mov")
        do {
            let startedAt = ProcessInfo.processInfo.systemUptime
            let movie = try frames.record(using: media, at: url)
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
            do { try FileManager.default.removeItem(at: url) }
            catch { failure = .file("\(failure.localizedDescription) Capture file remains at \(url.path): \(error.localizedDescription)") }
            recordingState = .failed(failure)
            throw failure
        }
    }

    /// Idempotent. Concurrent stop, close and quit callers share the same finish operation.
    @discardableResult
    public func stopRecording() async -> Result<URL, CaptureFailure>? {
        if let finishTask { return await finishTask.value }
        guard let movie else { return nil }
        frames.detachMovie()
        self.movie = nil
        monitor?.cancel()
        monitor = nil
        recordingState = .finishing
        onRecordingActivityChange?(false)
        let task = Task { await movie.finish() }
        finishTask = task
        let result = await task.value
        finishTask = nil
        recordingURL = nil
        switch result {
        case .success(let url): lastSavedURL = url; recordingState = .idle
        case .failure(let failure): recordingState = .failed(failure)
        }
        return result
    }
}
