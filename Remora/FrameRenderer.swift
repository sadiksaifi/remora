import AppKit
import RemoraCore
import Metal
import QuartzCore
import Synchronization
import os

private let renderLog = OSLog(subsystem: "dev.sadiksaifi.Remora", category: "Render")

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
    private let pipeline: any MTLRenderPipelineState
    private let nearest: any MTLSamplerState
    private let linear: any MTLSamplerState
    private let inFlight = Mutex(false)
    private let counters = Mutex(Statistics())

    init(device: any MTLDevice) throws(Failure) {
        self.device = device
        guard let library = device.makeDefaultLibrary() else {
            throw Failure.allocationFailed
        }
        do { desktop = try MetalDesktop(device: device) }
        catch { throw Failure.allocationFailed }
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
        do { copiedBytes = try desktop.ingest(frame) }
        catch { counters.withLock { $0.lastFailure = .commandFailed(error.localizedDescription) } }
    }

    /// The Debug demo uses the same frame path as a session.
    func ingest(pixels: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int, dirty: [DirtyRect]) {
        consume(BorrowedFrame(pixels: pixels, width: width, height: height, stride: bytesPerRow,
            dirtyRectangles: dirty.map { .init(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }))
    }

    @MainActor
    func present(on layer: CAMetalLayer, redraw: Bool) -> CGSize? {
        guard !inFlight.withLock({ $0 }), desktop.needsSubmission(redraw: redraw),
              layer.drawableSize.width > 0, layer.drawableSize.height > 0,
              let drawable = layer.nextDrawable() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        inFlight.withLock { $0 = true }
        do {
            let submission = try desktop.submit { texture, command in
                guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.allocationFailed }
                let size = CGSize(width: texture.width, height: texture.height)
                let geometry = DesktopGeometry(remoteSize: size, drawableSize: layer.drawableSize)
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
                    inFlight.withLock { $0 = false }
                    os_signpost(.end, log: renderLog, name: "Present", signpostID: signpost)
                }
                command.label = "Remote desktop presentation"
                command.present(drawable)
            }
            return CGSize(width: submission.size.width, height: submission.size.height)
        } catch {
            inFlight.withLock { $0 = false }
            counters.withLock { $0.lastFailure = .commandFailed(error.localizedDescription) }
            return nil
        }
    }
}
