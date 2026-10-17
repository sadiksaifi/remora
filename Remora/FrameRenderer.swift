import AppKit
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
final class FrameRenderer: Sendable {
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
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let nearest: any MTLSamplerState
    private let linear: any MTLSamplerState
    private let state = Mutex(State())
    private let counters = Mutex(Statistics())

    init(device: any MTLDevice) throws(Failure) {
        self.device = device
        guard let queue = device.makeCommandQueue(), let library = device.makeDefaultLibrary() else {
            throw Failure.allocationFailed
        }
        self.queue = queue
        queue.label = "Remote desktop"
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

    /// A pending frame that was never drawn still holds its slot. Release it, or libdispatch
    /// traps when it frees a semaphore below its initial value.
    deinit {
        state.withLock { $0.dropPending() }
    }

    convenience init() throws(Failure) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.metalUnavailable }
        try self.init(device: device)
    }

    var statistics: Statistics { counters.withLock { $0 } }

    /// Callable from any thread. The borrowed BGRA32 pointer is never retained.
    /// A new size copies the entire framebuffer, even if its damage list is partial.
    /// Allocation/command failures are available in `statistics.lastFailure`.
    func ingest(pixels: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int, dirty: [DirtyRect]) {
        let signpost = OSSignpostID(log: renderLog)
        os_signpost(.begin, log: renderLog, name: "Ingest", signpostID: signpost)
        var copiedBytes = 0
        defer { os_signpost(.end, log: renderLog, name: "Ingest", signpostID: signpost, "bytes=%{public}ld", copiedBytes) }
        // Apple silicon supports 2D textures up to 16384 pixels per dimension.
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              bytesPerRow >= width * 4, bytesPerRow <= Int.max / height else {
            counters.withLock { $0.lastFailure = .invalidFrame }
            return
        }
        state.withLock { state in
            let resized = state.storage?.width != width || state.storage?.height != height
            if resized {
                guard let storage = Storage(device: device, width: width, height: height) else {
                    counters.withLock { $0.lastFailure = .allocationFailed }
                    return
                }
                state.dropPending()
                state.storage = storage
                state.nextSlot = 0
            }
            guard let storage = state.storage else { return }
            var damage = FrameDamage()
            if resized {
                damage.insert(DirtyRect(x: 0, y: 0, width: width, height: height))
            } else {
                for rectangle in dirty {
                    if let clipped = rectangle.clipped(width: width, height: height) { damage.insert(clipped) }
                }
            }
            guard !damage.rectangles.isEmpty else { return }
            if state.pending == nil {
                let slot = storage.slots[state.nextSlot]
                // Completion signals without taking `state`, so this cannot deadlock.
                slot.available.wait()
                state.pending = state.nextSlot
                state.nextSlot = (state.nextSlot + 1) % storage.slots.count
            }
            let destination = storage.slots[state.pending!].buffer.contents()
            for rectangle in damage.rectangles {
                let rowBytes = rectangle.width * 4
                for y in rectangle.y..<(rectangle.y + rectangle.height) {
                    let xOffset = rectangle.x * 4
                    memcpy(destination + y * storage.bytesPerRow + xOffset, pixels + y * bytesPerRow + xOffset, rowBytes)
                }
                copiedBytes += rowBytes * rectangle.height
                state.damage.insert(rectangle)
            }
        }
    }

    /// Called only by the view's display link. Geometry changes count as display
    /// damage; otherwise an idle desktop never acquires a drawable or submits work.
    @MainActor
    func present(on layer: CAMetalLayer, redraw: Bool) -> CGSize? {
        let needed = state.withLock { !$0.inFlight && ($0.pending != nil || (redraw && $0.storage?.hasSubmitted == true)) }
        guard needed, layer.drawableSize.width > 0, layer.drawableSize.height > 0,
              let drawable = layer.nextDrawable(), let command = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        let submission: Submission? = state.withLock { state in
            guard let storage = state.storage, state.pending != nil || (redraw && storage.hasSubmitted) else { return nil }
            let slot = state.pending.map { storage.slots[$0] }
            let rectangles = state.damage.rectangles
            if let slot {
                guard let blit = command.makeBlitCommandEncoder() else { return nil }
                for rectangle in rectangles {
                    blit.copy(
                        from: slot.buffer,
                        sourceOffset: rectangle.y * storage.bytesPerRow + rectangle.x * 4,
                        sourceBytesPerRow: storage.bytesPerRow,
                        sourceBytesPerImage: 0,
                        sourceSize: MTLSize(width: rectangle.width, height: rectangle.height, depth: 1),
                        to: storage.texture, destinationSlice: 0, destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: rectangle.x, y: rectangle.y, z: 0)
                    )
                }
                blit.endEncoding()
            }
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            let geometry = DesktopGeometry(remoteSize: storage.size, drawableSize: layer.drawableSize)
            let rect = geometry.contentRect
            encoder.setViewport(MTLViewport(originX: rect.minX, originY: rect.minY, width: rect.width, height: rect.height, znear: 0, zfar: 1))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(storage.texture, index: 0)
            encoder.setFragmentSamplerState(geometry.isPixelExact ? nearest : linear, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            state.pending = nil
            state.damage = FrameDamage()
            state.inFlight = true
            storage.hasSubmitted = true
            return Submission(storage: storage, slot: slot, rectangleCount: rectangles.count)
        }
        guard let submission else { return nil }
        let signpost = OSSignpostID(log: renderLog)
        os_signpost(.begin, log: renderLog, name: "Present", signpostID: signpost, "rects=%{public}ld", submission.rectangleCount)
        counters.withLock { $0.submittedFrames += 1 }
        drawable.addPresentedHandler { [self] drawable in
            if drawable.presentedTime > 0 { counters.withLock { $0.presentedFrames += 1 } }
        }
        command.addCompletedHandler { [self] command in
            submission.slot?.available.signal()
            counters.withLock {
                $0.completedFrames += 1
                $0.gpuSeconds += max(0, command.gpuEndTime - command.gpuStartTime)
                if let error = command.error { $0.lastFailure = .commandFailed(error.localizedDescription) }
            }
            state.withLock {
                $0.inFlight = false
                if command.status == .error, $0.storage === submission.storage {
                    $0.dropPending()
                    $0.storage = nil
                }
            }
            os_signpost(.end, log: renderLog, name: "Present", signpostID: signpost, "rects=%{public}ld", submission.rectangleCount)
        }
        command.label = "Remote desktop: \(submission.rectangleCount) rectangles"
        command.present(drawable)
        command.commit()
        return submission.storage.size
    }

    private struct State {
        var storage: Storage?
        var pending: Int?
        var nextSlot = 0
        var inFlight = false
        var damage = FrameDamage()

        /// Discards the pending frame and gives its slot back.
        mutating func dropPending() {
            if let pending, let storage { storage.slots[pending].available.signal() }
            pending = nil
            damage = FrameDamage()
        }
    }

    private struct Submission: Sendable {
        let storage: Storage
        let slot: Slot?
        let rectangleCount: Int
    }

    // MTLBuffer's raw contents are not Sendable. Only ingest writes them under
    // `state`; the semaphore transfers exclusive ownership to/from the GPU.
    private final class Slot: @unchecked Sendable {
        let buffer: any MTLBuffer
        let available = DispatchSemaphore(value: 1)

        init(buffer: any MTLBuffer) { self.buffer = buffer }
    }

    // hasSubmitted is accessed only while holding the renderer's state lock.
    private final class Storage: @unchecked Sendable {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let texture: any MTLTexture
        let slots: [Slot]
        var hasSubmitted = false
        var size: CGSize { CGSize(width: width, height: height) }

        init?(device: any MTLDevice, width: Int, height: Int) {
            self.width = width
            self.height = height
            bytesPerRow = (width * 4 + 255) & ~255
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            self.texture = texture
            texture.label = "Remote BGRA framebuffer"
            var slots: [Slot] = []
            for index in 0..<3 {
                guard let buffer = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared) else { return nil }
                buffer.label = "Remote staging \(index)"
                slots.append(Slot(buffer: buffer))
            }
            self.slots = slots
        }
    }
}
