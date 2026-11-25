import AppKit
import Metal
import QuartzCore
import RemoraCore
import Synchronization
import os

private let renderLog = OSLog(subsystem: "com.peblon.remora", category: "Render")

/// Copies only damaged bytes into one pending staging slot. Three semaphore-owned
/// slots overlap CPU copies with GPU reads; a slot stays immutable until completion.
/// A slot is taken when it becomes pending and given back when its draw completes or when
/// the pending frame is dropped, so every semaphore is balanced before its storage is freed.
/// One serial queue blits exact damage into a private texture, then draws, in the
/// same command buffer, with at most one command buffer in flight. Pending ingests
/// overwrite/coalesce in place, never queue frames.
/// See https://developer.apple.com/documentation/metal/mtlblitcommandencoder.
final class FrameRenderer: FrameSink, Sendable {
    enum Failure: Error, LocalizedError, Sendable {
        case metalUnavailable
        case allocationFailed
        case pipelineCreationFailed(String)
        case invalidFrame
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .metalUnavailable: "Metal is unavailable."
            case .allocationFailed: "Metal could not allocate renderer resources."
            case .pipelineCreationFailed(let description): "Metal could not create the desktop pipeline: \(description)"
            case .invalidFrame: "The remote framebuffer dimensions or stride are invalid."
            case .commandFailed(let description): "Metal rendering failed: \(description)"
            }
        }
    }

    struct Statistics: Sendable {
        fileprivate(set) var submittedFrames: UInt64 = 0
        fileprivate(set) var completedFrames: UInt64 = 0
        fileprivate(set) var presentedFrames: UInt64 = 0
        fileprivate(set) var gpuSeconds: Double = 0
        fileprivate(set) var lastFailure: Failure?
    }

    let device: any MTLDevice
    let desktop: MetalDesktop
    var metalDesktop: MetalDesktop? { desktop }
    private let pipeline: any MTLRenderPipelineState
    private let nearest: any MTLSamplerState
    private let linear: any MTLSamplerState
    // Space submissions by a refresh interval so drawables cannot queue behind vsync.
    // Acquisition stays off the main thread even when the window is occluded.
    private let presentationQueue = DispatchQueue(label: "Remote desktop presentation", qos: .userInteractive)
    private let presentation = Mutex((inFlight: false, requested: false, earliest: CFTimeInterval.zero, submittedRevision: 0))
    private let counters = Mutex(Statistics())

    init(device: any MTLDevice) throws(Failure) {
        self.device = device
        guard let library = device.makeDefaultLibrary() else {
            throw Failure.allocationFailed
        }
        do { desktop = try MetalDesktop(device: device) } catch { throw Failure.allocationFailed }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Opaque BGRA desktop"
        descriptor.vertexFunction = library.makeFunction(name: "remoraDesktopVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "remoraDesktopFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw .pipelineCreationFailed(error.localizedDescription)
        }
        let sampler = MTLSamplerDescriptor()
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge
        sampler.minFilter = .nearest
        sampler.magFilter = .nearest
        guard let nearest = device.makeSamplerState(descriptor: sampler) else { throw Failure.allocationFailed }
        self.nearest = nearest
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        guard let linear = device.makeSamplerState(descriptor: sampler) else { throw Failure.allocationFailed }
        self.linear = linear
    }

    convenience init() throws(Failure) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.metalUnavailable }
        try self.init(device: device)
    }

    var statistics: Statistics { counters.withLock { $0 } }

    /// The shared framebuffer performs the original renderer's dirty uploads.
    func consume(_ frame: BorrowedFrame) {
        let signpost = OSSignpostID(log: renderLog)
        os_signpost(.begin, log: renderLog, name: "Ingest", signpostID: signpost)
        var copiedBytes = 0
        defer { os_signpost(.end, log: renderLog, name: "Ingest", signpostID: signpost, "bytes=%{public}ld", copiedBytes) }
        do { copiedBytes = try desktop.ingest(frame) } catch { counters.withLock { $0.lastFailure = .commandFailed(error.localizedDescription) } }
    }

    /// The Debug demo uses the same frame path as a session.
    func ingest(pixels: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int, dirty: [DirtyRect]) {
        consume(
            BorrowedFrame(
                pixels: pixels, width: width, height: height, stride: bytesPerRow,
                dirtyRectangles: dirty.map { .init(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }))
    }

    @MainActor
    func present(
        on layer: CAMetalLayer, redraw: Bool, interval: CFTimeInterval,
        didComplete: @escaping @MainActor @Sendable (CGSize?) -> Void
    ) {
        let drawableSize = layer.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        let deadline = presentation.withLock { state -> CFTimeInterval? in
            guard !state.inFlight else {
                state.requested = true
                return nil
            }
            state.inFlight = true
            return state.earliest
        }
        guard let deadline else { return }
        // draw(on:) calls only nextDrawable() on the layer, which is safe off the main thread.
        nonisolated(unsafe) let layer = layer
        presentationQueue.asyncAfter(deadline: .now() + max(0, deadline - CACurrentMediaTime())) { [self] in
            autoreleasepool { draw(on: layer, redraw: redraw, interval: interval, didComplete: didComplete) }
        }
    }

    private func finish(
        size: CGSize?, retry: Bool,
        didComplete: @escaping @MainActor @Sendable (CGSize?) -> Void
    ) {
        let requested = presentation.withLock { state in
            state.inFlight = false
            defer { state.requested = false }
            return state.requested
        }
        if size != nil || retry || requested {
            DispatchQueue.main.async { didComplete(size) }
        }
    }

    private func draw(
        on layer: CAMetalLayer, redraw: Bool, interval: CFTimeInterval,
        didComplete: @escaping @MainActor @Sendable (CGSize?) -> Void
    ) {
        let submittedRevision = presentation.withLock { $0.submittedRevision }
        guard desktop.needsSubmission(since: submittedRevision, redraw: redraw) else {
            finish(size: nil, retry: false, didComplete: didComplete)
            return
        }
        presentation.withLock { $0.earliest = CACurrentMediaTime() + interval }
        guard let drawable = layer.nextDrawable() else {
            finish(size: nil, retry: true, didComplete: didComplete)
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        do {
            let submission = try desktop.submit(presenting: true) { texture, command in
                guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.allocationFailed }
                let size = CGSize(width: texture.width, height: texture.height)
                let drawableSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
                let geometry = DesktopGeometry(remoteSize: size, drawableSize: drawableSize)
                let rect = geometry.contentRect
                encoder.setViewport(MTLViewport(originX: rect.minX, originY: rect.minY, width: rect.width, height: rect.height, znear: 0, zfar: 1))
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentSamplerState(geometry.isPixelExact ? nearest : linear, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                encoder.endEncoding()
                let signpost = OSSignpostID(log: renderLog)
                os_signpost(.begin, log: renderLog, name: "Present", signpostID: signpost)
                counters.withLock { $0.submittedFrames += 1 }
                drawable.addPresentedHandler { [self] drawable in
                    if drawable.presentedTime > 0 { counters.withLock { $0.presentedFrames += 1 } }
                }
                command.addCompletedHandler { [self] command in
                    counters.withLock {
                        $0.completedFrames += 1
                        $0.gpuSeconds += max(0, command.gpuEndTime - command.gpuStartTime)
                        if let error = command.error { $0.lastFailure = .commandFailed(error.localizedDescription) }
                    }
                    finish(size: command.status == .error ? nil : size, retry: true, didComplete: didComplete)
                    os_signpost(.end, log: renderLog, name: "Present", signpostID: signpost)
                }
                command.label = "Remote desktop presentation"
                presentation.withLock { $0.earliest = CACurrentMediaTime() + interval }
                command.present(drawable)
            }
            guard let submission else {
                // A held desktop publishes, and so asks for this presentation again, when it is released.
                finish(size: nil, retry: false, didComplete: didComplete)
                return
            }
            presentation.withLock { $0.submittedRevision = submission.revision }
        } catch {
            counters.withLock { $0.lastFailure = .commandFailed(error.localizedDescription) }
            finish(size: nil, retry: true, didComplete: didComplete)
        }
    }
}
