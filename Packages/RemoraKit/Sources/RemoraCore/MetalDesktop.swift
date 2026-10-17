import Foundation
import Metal
import Synchronization

/// The renderer's existing framebuffer and staging slots. Capture adds only an optional observer.
/// No drawable is needed to flush damage, read an idle desktop, or encode a hidden tab.
public final class MetalDesktop: CaptureSource, Sendable {
    public let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let state = Mutex(State())

    public init(device: any MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw CaptureFailure.image("No Metal command queue.") }
        self.queue = queue
        queue.label = "Remote desktop"
    }

    deinit { state.withLock { $0.dropPending() } }

    public var size: DesktopSize? { state.withLock { $0.storage?.size } }
    public func needsSubmission(redraw: Bool) -> Bool {
        state.withLock { $0.pending != nil || (redraw && $0.storage?.hasSubmitted == true) }
    }

    public func setFrameObserver(_ observer: (@Sendable (TimeInterval) -> Void)?) {
        state.withLock {
            $0.observer = observer
            if observer != nil, $0.storage != nil {
                $0.arrival = ProcessInfo.processInfo.systemUptime
                observer?($0.arrival)
            }
        }
    }

    /// Only the renderer's original dirty-rectangle copies. No capture work unless an observer is installed.
    @discardableResult
    public func ingest(_ frame: BorrowedFrame) throws -> Int {
        guard frame.width > 0, frame.height > 0, frame.width <= 16_384, frame.height <= 16_384,
              frame.stride >= frame.width * 4, frame.stride <= Int.max / frame.height else {
            throw CaptureFailure.image("Invalid framebuffer dimensions or stride.")
        }
        return try state.withLock { state in
            let resized = state.storage?.width != frame.width || state.storage?.height != frame.height
            if resized {
                let storage = try Storage(device: device, width: frame.width, height: frame.height)
                state.dropPending()
                state.storage = storage
                state.nextSlot = 0
            }
            guard let storage = state.storage else { return 0 }
            var damage = FrameDamage()
            if resized { damage.insert(.init(x: 0, y: 0, width: frame.width, height: frame.height)) }
            else {
                for rectangle in frame.dirtyRectangles {
                    if let clipped = rectangle.clipped(width: frame.width, height: frame.height) { damage.insert(clipped) }
                }
            }
            guard !damage.rectangles.isEmpty else { return 0 }
            if state.pending == nil {
                let slot = storage.slots[state.nextSlot]
                // GPU completion returns the slot before taking state, as in the original renderer.
                slot.available.wait()
                state.pending = state.nextSlot
                state.nextSlot = (state.nextSlot + 1) % storage.slots.count
            }
            let destination = storage.slots[state.pending!].buffer.contents()
            var copied = 0
            for rectangle in damage.rectangles {
                let rowBytes = rectangle.width * 4
                for y in rectangle.y..<(rectangle.y + rectangle.height) {
                    let offset = rectangle.x * 4
                    memcpy(destination + y * storage.bytesPerRow + offset,
                           frame.pixels + y * frame.stride + offset, rowBytes)
                }
                copied += rowBytes * rectangle.height
                state.damage.insert(rectangle)
            }
            // No clock read or notification unless recording has installed an observer.
            if let observer = state.observer {
                state.arrival = ProcessInfo.processInfo.systemUptime
                observer(state.arrival)
            }
            return copied
        }
    }

    public struct Submission {
        public let command: any MTLCommandBuffer
        public let size: DesktopSize
        public let arrival: TimeInterval
        public let rectangleCount: Int
    }

    /// Flushes pending uploads and reserves queue order under the existing renderer lock.
    /// The caller's encoding and GPU wait happen outside it. Every enqueued command is committed,
    /// including when the caller throws, so neither a staging semaphore nor the queue is stranded.
    public func submit(_ encode: (any MTLTexture, any MTLCommandBuffer) throws -> Void) throws -> Submission {
        let prepared = try state.withLock { state -> (Submission, any MTLTexture) in
            guard let storage = state.storage else { throw CaptureFailure.noFrame }
            guard let command = queue.makeCommandBuffer() else { throw CaptureFailure.image("No Metal command buffer.") }
            let slot = state.pending.map { storage.slots[$0] }
            let rectangles = state.damage.rectangles
            if let slot {
                guard let blit = command.makeBlitCommandEncoder() else { throw CaptureFailure.image("No Metal blit encoder.") }
                for rectangle in rectangles {
                    blit.copy(from: slot.buffer,
                              sourceOffset: rectangle.y * storage.bytesPerRow + rectangle.x * 4,
                              sourceBytesPerRow: storage.bytesPerRow, sourceBytesPerImage: 0,
                              sourceSize: MTLSize(width: rectangle.width, height: rectangle.height, depth: 1),
                              to: storage.texture, destinationSlice: 0, destinationLevel: 0,
                              destinationOrigin: MTLOrigin(x: rectangle.x, y: rectangle.y, z: 0))
                }
                blit.endEncoding()
            }
            command.addCompletedHandler { [self] command in
                slot?.available.signal()
                if command.status == .error {
                    self.state.withLock {
                        if $0.storage === storage { $0.dropPending(); $0.storage = nil }
                    }
                }
            }
            state.pending = nil
            state.damage = FrameDamage()
            storage.hasSubmitted = true
            // enqueue, rather than commit, establishes order without encoding under the ingest lock.
            command.enqueue()
            return (Submission(command: command, size: storage.size, arrival: state.arrival,
                               rectangleCount: rectangles.count), storage.texture)
        }
        do { try encode(prepared.1, prepared.0.command) }
        catch { prepared.0.command.commit(); throw error }
        prepared.0.command.commit()
        return prepared.0
    }

    /// One readback on demand. Pending hidden-tab uploads are included before the full texture copy.
    public func snapshot() throws -> CaptureFrame {
        var readback: (any MTLBuffer)?
        var stride = 0
        let submission = try submit { texture, command in
            stride = (texture.width * 4 + 255) & ~255
            guard let buffer = device.makeBuffer(length: stride * texture.height, options: .storageModeShared),
                  let blit = command.makeBlitCommandEncoder() else { throw CaptureFailure.image("Could not allocate desktop readback.") }
            readback = buffer
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                      sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                      to: buffer, destinationOffset: 0, destinationBytesPerRow: stride,
                      destinationBytesPerImage: stride * texture.height)
            blit.endEncoding()
        }
        submission.command.waitUntilCompleted()
        guard submission.command.status == .completed, let readback else {
            throw CaptureFailure.image(submission.command.error?.localizedDescription ?? "Desktop readback failed.")
        }
        return CaptureFrame(copying: BorrowedFrame(pixels: readback.contents(), width: submission.size.width,
            height: submission.size.height, stride: stride, dirtyRectangles: []), arrival: submission.arrival)
    }

    private struct State {
        var storage: Storage?
        var pending: Int?
        var nextSlot = 0
        var damage = FrameDamage()
        var observer: (@Sendable (TimeInterval) -> Void)?
        var arrival: TimeInterval = 0

        mutating func dropPending() {
            if let pending, let storage { storage.slots[pending].available.signal() }
            pending = nil
            damage = FrameDamage()
        }
    }

    private final class Slot: @unchecked Sendable {
        let buffer: any MTLBuffer
        let available = DispatchSemaphore(value: 1)
        init(buffer: any MTLBuffer) { self.buffer = buffer }
    }

    private final class Storage: @unchecked Sendable {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let texture: any MTLTexture
        let slots: [Slot]
        var hasSubmitted = false
        var size: DesktopSize { .init(width: width, height: height) }

        init(device: any MTLDevice, width: Int, height: Int) throws {
            self.width = width
            self.height = height
            bytesPerRow = (width * 4 + 255) & ~255
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw CaptureFailure.image("No desktop texture.") }
            self.texture = texture
            texture.label = "Remote BGRA framebuffer"
            var slots: [Slot] = []
            for index in 0..<3 {
                guard let buffer = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared) else {
                    throw CaptureFailure.image("No desktop staging buffer.")
                }
                buffer.label = "Remote staging \(index)"
                slots.append(Slot(buffer: buffer))
            }
            self.slots = slots
        }
    }
}
