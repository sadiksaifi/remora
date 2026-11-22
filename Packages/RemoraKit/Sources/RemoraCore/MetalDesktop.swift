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
    public var revision: Int { state.withLock { $0.revision } }
    /// How many times a GPU error discarded the framebuffer. Pixels drawn only on the GPU went with it.
    public var losses: Int { state.withLock { $0.losses } }
    public var lastFrameArrival: TimeInterval? { state.withLock { $0.storage == nil ? nil : $0.arrival } }

    /// Each view tracks its submitted revision. Captures may upload that frame first.
    public func needsSubmission(since revision: Int, redraw: Bool) -> Bool {
        state.withLock { $0.storage != nil && ($0.revision != revision || redraw) }
    }

    /// Callbacks only enqueue work. Never take a snapshot from inside a callback.
    public func addFrameObserver(_ observer: @escaping @Sendable (TimeInterval) -> Void) -> UUID {
        let id = UUID()
        state.withLock {
            $0.observers[id] = observer
            if $0.storage != nil { observer($0.arrival) }
        }
        return id
    }

    public func removeFrameObserver(_ id: UUID) { _ = state.withLock { $0.observers.removeValue(forKey: id) } }

    /// Runs on a Metal thread each time a GPU error discards the framebuffer, and pixels drawn only on the GPU with it.
    public func addLossObserver(_ observer: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        state.withLock { $0.lossObservers[id] = observer }
        return id
    }

    public func removeLossObserver(_ id: UUID) { _ = state.withLock { $0.lossObservers.removeValue(forKey: id) } }
    var lossObserverCount: Int { state.withLock { $0.lossObservers.count } }

    /// Only the renderer's original dirty-rectangle copies. No capture work unless an observer is installed.
    @discardableResult
    public func ingest(_ frame: BorrowedFrame) throws -> Int {
        guard frame.width > 0, frame.height > 0, frame.width <= 16_384, frame.height <= 16_384,
            frame.stride >= frame.width * 4, frame.stride <= Int.max / frame.height
        else {
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
            if resized {
                damage.insert(contentsOf: [.init(x: 0, y: 0, width: frame.width, height: frame.height)])
            } else {
                damage.insert(contentsOf: frame.dirtyRectangles.lazy.compactMap { $0.clipped(width: frame.width, height: frame.height) })
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
                    memcpy(
                        destination + y * storage.bytesPerRow + offset,
                        frame.pixels + y * frame.stride + offset, rowBytes)
                }
                copied += rowBytes * rectangle.height
            }
            state.damage.insert(contentsOf: damage.rectangles)
            state.revision += 1
            state.arrival = ProcessInfo.processInfo.systemUptime
            for observer in state.observers.values { observer(state.arrival) }
            return copied
        }
    }

    public struct Submission {
        public let command: any MTLCommandBuffer
        public let size: DesktopSize
        public let arrival: TimeInterval
        public let revision: Int
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
                    blit.copy(
                        from: slot.buffer,
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
                if command.status == .error { discardFramebuffer(drawnInto: storage.texture) }
            }
            state.pending = nil
            state.damage = FrameDamage()
            // enqueue, rather than commit, establishes order without encoding under the ingest lock.
            command.enqueue()
            return (
                Submission(
                    command: command, size: storage.size, arrival: state.arrival,
                    revision: state.revision, rectangleCount: rectangles.count), storage.texture
            )
        }
        do { try encode(prepared.1, prepared.0.command) } catch {
            prepared.0.command.commit()
            throw error
        }
        prepared.0.command.commit()
        return prepared.0
    }

    /// GPU drawing straight into the framebuffer, ordered after every earlier upload and draw.
    /// `encode` learns whether the framebuffer is new at this size; a new one holds undefined pixels,
    /// so the caller clears it to zero, as a new CPU framebuffer starts.
    /// The frame is published like an ingested one once the work is committed.
    public func draw(
        width: Int, height: Int, _ encode: (any MTLTexture, any MTLCommandBuffer, _ created: Bool) throws -> Void
    ) throws {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384 else {
            throw CaptureFailure.image("Invalid framebuffer dimensions.")
        }
        let created = try state.withLock { state -> Bool in
            guard state.storage?.width != width || state.storage?.height != height else { return false }
            let storage = try Storage(device: device, width: width, height: height)
            state.dropPending()
            state.storage = storage
            state.nextSlot = 0
            return true
        }
        _ = try submit { texture, command in try encode(texture, command, created) }
        state.withLock { state in
            state.revision += 1
            state.arrival = ProcessInfo.processInfo.systemUptime
            for observer in state.observers.values { observer(state.arrival) }
        }
    }

    /// After GPU work on `texture` fails, the framebuffer holds undefined pixels, including those only the GPU drew.
    /// It is dropped, and the next frame makes a new one. A failure in an older framebuffer leaves the current one.
    func discardFramebuffer(drawnInto texture: any MTLTexture) {
        let observers = state.withLock { state -> [@Sendable () -> Void] in
            guard let storage = state.storage, storage.texture === texture else { return [] }
            state.dropPending()
            state.storage = nil
            state.losses += 1
            return Array(state.lossObservers.values)
        }
        for observer in observers { observer() }
    }

    /// Copies framebuffer rectangles as BGRA bytes, after all earlier uploads and draws, in one GPU round trip.
    /// `pixels` is an image whose top-left pixel is the framebuffer pixel at `originX`, `originY`.
    public func read(
        _ rectangles: [DirtyRectangle], into pixels: UnsafeMutableRawPointer, stride: Int, originX: Int = 0, originY: Int = 0
    ) throws {
        let rectangles = rectangles.filter { $0.width > 0 && $0.height > 0 }
        guard !rectangles.isEmpty else { return }
        // Each rectangle gets its own rows in one shared buffer.
        var offsets: [Int] = []
        var length = 0
        for r in rectangles {
            offsets.append(length)
            length += ((r.width * 4 + 255) & ~255) * r.height
        }
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            throw CaptureFailure.image("Could not allocate desktop readback.")
        }
        let submission = try submit { texture, command in
            guard let blit = command.makeBlitCommandEncoder() else { throw CaptureFailure.image("No Metal blit encoder.") }
            defer { blit.endEncoding() }
            for (r, offset) in zip(rectangles, offsets) {
                guard r.x >= 0, r.y >= 0, r.x + r.width <= texture.width, r.y + r.height <= texture.height else {
                    throw CaptureFailure.image("Readback outside the desktop.")
                }
                let rowBytes = (r.width * 4 + 255) & ~255
                blit.copy(
                    from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: r.x, y: r.y, z: 0),
                    sourceSize: MTLSize(width: r.width, height: r.height, depth: 1),
                    to: buffer, destinationOffset: offset, destinationBytesPerRow: rowBytes,
                    destinationBytesPerImage: rowBytes * r.height)
            }
        }
        submission.command.waitUntilCompleted()
        guard submission.command.status == .completed else {
            throw CaptureFailure.image(submission.command.error?.localizedDescription ?? "Desktop readback failed.")
        }
        for (r, offset) in zip(rectangles, offsets) {
            let rowBytes = (r.width * 4 + 255) & ~255
            let destination = pixels + (r.y - originY) * stride + (r.x - originX) * 4
            for row in 0..<r.height {
                memcpy(destination + row * stride, buffer.contents() + offset + row * rowBytes, r.width * 4)
            }
        }
    }

    /// One readback on demand. Pending hidden-tab uploads are included before the full texture copy.
    public func snapshot() throws -> CaptureFrame {
        var readback: (any MTLBuffer)?
        var stride = 0
        let submission = try submit { texture, command in
            stride = (texture.width * 4 + 255) & ~255
            guard let buffer = device.makeBuffer(length: stride * texture.height, options: .storageModeShared),
                let blit = command.makeBlitCommandEncoder()
            else { throw CaptureFailure.image("Could not allocate desktop readback.") }
            readback = buffer
            blit.copy(
                from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                to: buffer, destinationOffset: 0, destinationBytesPerRow: stride,
                destinationBytesPerImage: stride * texture.height)
            blit.endEncoding()
        }
        submission.command.waitUntilCompleted()
        guard submission.command.status == .completed, let readback else {
            throw CaptureFailure.image(submission.command.error?.localizedDescription ?? "Desktop readback failed.")
        }
        return CaptureFrame(
            copying: BorrowedFrame(
                pixels: readback.contents(), width: submission.size.width,
                height: submission.size.height, stride: stride, dirtyRectangles: []), arrival: submission.arrival, revision: submission.revision)
    }

    private struct State {
        var storage: Storage?
        var pending: Int?
        var nextSlot = 0
        var damage = FrameDamage()
        var observers: [UUID: @Sendable (TimeInterval) -> Void] = [:]
        var lossObservers: [UUID: @Sendable () -> Void] = [:]
        var revision = 0
        var arrival: TimeInterval = 0
        var losses = 0

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
        var size: DesktopSize { .init(width: width, height: height) }

        init(device: any MTLDevice, width: Int, height: Int) throws {
            self.width = width
            self.height = height
            bytesPerRow = (width * 4 + 255) & ~255
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
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
