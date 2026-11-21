import CoreVideo
import Foundation
import Metal

/// Converts decoded H.264 pictures to BGRA on the GPU, straight into the desktop framebuffer.
/// The kernels repeat FreeRDP 3.33.1's integer arithmetic on Apple silicon (`prim_YUV_neon.c`, `yuv.c`),
/// including its rectangle-relative chroma phase and the AVC444 chroma filter, so the pixels match its
/// CPU conversion byte for byte. Use from one thread: the graphics channel's.
public final class H264Renderer: @unchecked Sendable {
    public enum Layout: Sendable {
        /// Convert the 4:2:0 picture directly (AVC420).
        case yuv420
        /// Merge into the surface's 4:4:4 planes, then convert (AVC444 main view, MS-RDPEGFX 3.3.8.3.1).
        case luma
        /// AVC444 auxiliary view (3.3.8.3.2).
        case chromaV1
        /// AVC444v2 auxiliary view (3.3.8.3.3).
        case chromaV2
    }

    public struct Rectangle: Sendable, Equatable {
        public let left, top, right, bottom: Int
        public init(left: Int, top: Int, right: Int, bottom: Int) {
            self.left = left
            self.top = top
            self.right = right
            self.bottom = bottom
        }
    }

    public struct Pass {
        public let layout: Layout
        /// Three-plane I420 that Metal can read.
        public let image: CVPixelBuffer
        /// Surface coordinates, within the image and the surface.
        public let rectangles: [Rectangle]
        /// Conversion clamps the rectangles to this height; merging does not.
        public let convertHeight: Int
        public init(layout: Layout, image: CVPixelBuffer, rectangles: [Rectangle], convertHeight: Int) {
            self.layout = layout
            self.image = image
            self.rectangles = rectangles
            self.convertHeight = convertHeight
        }
    }

    public struct Target: Sendable {
        public let surface: UInt16
        public let surfaceWidth, surfaceHeight: Int
        /// Desktop position of the surface's top-left pixel.
        public let originX, originY: Int
        /// Surface area that lands on the desktop.
        public let visibleWidth, visibleHeight: Int
        public let desktopWidth, desktopHeight: Int
        public init(
            surface: UInt16, surfaceWidth: Int, surfaceHeight: Int, originX: Int, originY: Int,
            visibleWidth: Int, visibleHeight: Int, desktopWidth: Int, desktopHeight: Int
        ) {
            self.surface = surface
            self.surfaceWidth = surfaceWidth
            self.surfaceHeight = surfaceHeight
            self.originX = originX
            self.originY = originY
            self.visibleWidth = visibleWidth
            self.visibleHeight = visibleHeight
            self.desktopWidth = desktopWidth
            self.desktopHeight = desktopHeight
        }
    }

    private let desktop: MetalDesktop
    private let device: any MTLDevice
    private let cache: CVMetalTextureCache
    private let pipelines: [String: any MTLComputePipelineState]
    /// FreeRDP's persistent YUV444 buffers, one set per surface. They start zeroed, as FreeRDP's do.
    private var planes: [UInt16: Planes] = [:]

    /// Core Video buffers held until a command buffer completes. Only released, never read, on the handler's thread.
    private final class Retained: @unchecked Sendable {
        let buffers: [CVBuffer]
        init(_ buffers: [CVBuffer]) { self.buffers = buffers }
    }

    private final class Planes {
        let width, height: Int
        let y, u, v: any MTLTexture
        var cleared = false
        init(width: Int, height: Int, y: any MTLTexture, u: any MTLTexture, v: any MTLTexture) {
            self.width = width
            self.height = height
            self.y = y
            self.u = u
            self.v = v
        }
    }

    /// Mirrors `struct Pass` in the kernels.
    private struct Uniforms {
        var left: Int32, top: Int32, width: Int32, height: Int32
        var offsetX: Int32, offsetY: Int32, visibleWidth: Int32, visibleHeight: Int32
        var totalWidth: Int32
    }

    public init(desktop: MetalDesktop) throws {
        self.desktop = desktop
        device = desktop.device
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw CaptureFailure.image("No Metal texture cache.")
        }
        self.cache = cache
        let library = try device.makeLibrary(source: Self.source, options: nil)
        var pipelines: [String: any MTLComputePipelineState] = [:]
        for name in library.functionNames {
            guard let function = library.makeFunction(name: name) else { continue }
            pipelines[name] = try device.makeComputePipelineState(function: function)
        }
        self.pipelines = pipelines
    }

    /// Runs the passes in order, as FreeRDP's `avc420_decompress` and `avc444_decompress` do.
    public func draw(_ target: Target, passes: [Pass]) throws {
        var keep: [CVMetalTexture] = []
        var sources: [[any MTLTexture]] = []
        for pass in passes {
            var textures: [any MTLTexture] = []
            for plane in 0..<3 {
                let (texture, owner) = try planeTexture(pass.image, plane: plane)
                textures.append(texture)
                keep.append(owner)
            }
            sources.append(textures)
        }
        let needsPlanes = passes.contains { $0.layout != .yuv420 }
        let surfacePlanes = needsPlanes ? try planes(for: target) : nil
        let retained = Retained(keep + passes.map(\.image))
        try desktop.draw(width: target.desktopWidth, height: target.desktopHeight) { texture, command, created in
            guard let encoder = command.makeComputeCommandEncoder() else { throw CaptureFailure.image("No Metal compute encoder.") }
            defer { encoder.endEncoding() }
            // Core Video textures and their pictures must outlive the GPU work.
            command.addCompletedHandler { _ in withExtendedLifetime(retained) {} }
            if created { dispatch(encoder, "clearDesktop", [texture], width: texture.width, height: texture.height, nil) }
            if let surfacePlanes, !surfacePlanes.cleared {
                for plane in [surfacePlanes.y, surfacePlanes.u, surfacePlanes.v] {
                    dispatch(encoder, "clearPlane", [plane], width: plane.width, height: plane.height, nil)
                }
                surfacePlanes.cleared = true
            }
            for (pass, source) in zip(passes, sources) {
                try encode(pass, source: source, planes: surfacePlanes, desktop: texture, target: target, encoder: encoder)
            }
        }
        CVMetalTextureCacheFlush(cache, 0)
    }

    /// Copies desktop rectangles as BGRA, after all earlier drawing. See `MetalDesktop.read`.
    public func read(
        _ rectangles: [DirtyRectangle], into pixels: UnsafeMutableRawPointer, stride: Int, originX: Int, originY: Int
    ) throws {
        try desktop.read(rectangles, into: pixels, stride: stride, originX: originX, originY: originY)
    }

    public func removeSurface(_ surface: UInt16) {
        planes[surface] = nil
    }

    private func planes(for target: Target) throws -> Planes {
        // Merging may write up to two pixels right of and one row below a rectangle, as FreeRDP's padded buffer allows.
        let width = target.surfaceWidth + 16
        let height = target.surfaceHeight + 16
        if let existing = planes[target.surface], existing.width == width, existing.height == height {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let y = device.makeTexture(descriptor: descriptor), let u = device.makeTexture(descriptor: descriptor),
            let v = device.makeTexture(descriptor: descriptor)
        else { throw CaptureFailure.image("No YUV444 planes.") }
        let created = Planes(width: width, height: height, y: y, u: u, v: v)
        planes[target.surface] = created
        return created
    }

    private func planeTexture(_ image: CVPixelBuffer, plane: Int) throws -> (any MTLTexture, CVMetalTexture) {
        guard CVPixelBufferGetPlaneCount(image) == 3 else { throw CaptureFailure.image("H.264 picture is not three-plane I420.") }
        var owner: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, image, nil, .r8Uint, CVPixelBufferGetWidthOfPlane(image, plane),
            CVPixelBufferGetHeightOfPlane(image, plane), plane, &owner)
        guard status == kCVReturnSuccess, let owner, let texture = CVMetalTextureGetTexture(owner) else {
            throw CaptureFailure.image("H.264 picture plane \(plane) is not readable by Metal (\(status)).")
        }
        return (texture, owner)
    }

    private func encode(
        _ pass: Pass, source: [any MTLTexture], planes: Planes?, desktop: any MTLTexture, target: Target,
        encoder: any MTLComputeCommandEncoder
    ) throws {
        // AVC444v2's nTotalWidth: the surface width aligned to 32, capped at the auxiliary luma stride (yuv.c).
        // When the surface width is not a multiple of 32, the rightmost V samples lie past the picture's width.
        // FreeRDP then reads the plane's row padding, which holds no picture; the kernels read 0.
        let alignedWidth = (target.surfaceWidth + 31) & ~31
        let totalWidth = min(alignedWidth, CVPixelBufferGetBytesPerRowOfPlane(pass.image, 0))
        func uniforms(_ r: Rectangle, height: Int? = nil) -> Uniforms {
            let bottom = height.map { min(r.bottom, $0) } ?? r.bottom
            let top = height.map { min(r.top, $0) } ?? r.top
            return Uniforms(
                left: Int32(r.left), top: Int32(top), width: Int32(r.right - r.left), height: Int32(max(0, bottom - top)),
                offsetX: Int32(target.originX), offsetY: Int32(target.originY),
                visibleWidth: Int32(target.visibleWidth), visibleHeight: Int32(target.visibleHeight),
                totalWidth: Int32(totalWidth))
        }
        let rectangles = pass.rectangles.filter { $0.right > $0.left && $0.bottom > $0.top }
        guard let planes else {
            // AVC420: one conversion per rectangle, in order.
            for r in rectangles {
                var u = uniforms(r, height: pass.convertHeight)
                dispatch(encoder, "convert420", source + [desktop], width: Int(u.width), height: Int(u.height), &u)
            }
            return
        }
        let yuv444 = [planes.y, planes.u, planes.v]
        // yuv444_context_decode merges every rectangle, then converts every rectangle.
        for r in rectangles {
            var u = uniforms(r)
            let w = r.right - r.left
            let h = r.bottom - r.top
            switch pass.layout {
            case .yuv420:
                throw CaptureFailure.image("A 4:2:0 pass cannot merge.")
            case .luma:
                dispatch(encoder, "mergeLuma", source + yuv444, width: 2 * ((w + 1) / 2), height: 2 * ((h + 1) / 2), &u)
            case .chromaV1:
                dispatch(encoder, "mergeChromaV1Rows", source + yuv444, width: w, height: h, &u)
                dispatch(encoder, "mergeChromaV1Columns", source + yuv444, width: w / 2, height: h / 2, &u)
            case .chromaV2:
                dispatch(encoder, "mergeChromaV2Columns", source + yuv444, width: (w + 1) / 2, height: h, &u)
                dispatch(encoder, "mergeChromaV2Rows", source + yuv444, width: (w + 3) / 4, height: (h + 1) / 2, &u)
            }
        }
        for r in rectangles {
            var u = uniforms(r, height: pass.convertHeight)
            dispatch(encoder, "convert444", yuv444 + [desktop], width: (Int(u.width) + 1) / 2, height: (Int(u.height) + 1) / 2, &u)
        }
    }

    private func dispatch(
        _ encoder: any MTLComputeCommandEncoder, _ name: String, _ textures: [any MTLTexture], width: Int, height: Int,
        _ uniforms: UnsafeMutablePointer<Uniforms>?
    ) {
        guard width > 0, height > 0, let pipeline = pipelines[name] else { return }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
        if let uniforms { encoder.setBytes(uniforms, length: MemoryLayout<Uniforms>.stride, index: 0) }
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    }

    static let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct Pass {
            int left, top, width, height;
            int offsetX, offsetY, visibleWidth, visibleHeight;
            int totalWidth;
        };

        typedef texture2d<uint, access::read> Plane;
        typedef texture2d<uint, access::read_write> Plane444;

        // Out-of-range reads return 0; FreeRDP would read stride padding there.
        static uint at(Plane t, int x, int y) {
            return (x >= 0 && y >= 0 && uint(x) < t.get_width() && uint(y) < t.get_height()) ? t.read(uint2(x, y)).r : 0;
        }
        static uint at(Plane444 t, int x, int y) {
            return (x >= 0 && y >= 0 && uint(x) < t.get_width() && uint(y) < t.get_height()) ? t.read(uint2(x, y)).r : 0;
        }
        static void put(Plane444 t, int x, int y, uint value) {
            if (x >= 0 && y >= 0 && uint(x) < t.get_width() && uint(y) < t.get_height()) t.write(uint4(value), uint2(x, y));
        }

        // prim_internal.h YUV2R/G/B: R = (256Y + 403(V-128)) >> 8, G = (256Y - 48(U-128) - 120(V-128)) >> 8,
        // B = (256Y + 475(U-128)) >> 8, arithmetic shift, clamped to 0...255.
        static void pixel(texture2d<float, access::write> desktop, constant Pass& p, int x, int y, int Y, int U, int V) {
            if (x >= p.visibleWidth || y >= p.visibleHeight) return;
            const int c = Y << 8, d = U - 128, e = V - 128;
            const int r = clamp((c + 403 * e) >> 8, 0, 255);
            const int g = clamp((c - (48 * d + 120 * e)) >> 8, 0, 255);
            const int b = clamp((c + 475 * d) >> 8, 0, 255);
            desktop.write(float4(r, g, b, 255) / 255.0f, uint2(x + p.offsetX, y + p.offsetY));
        }

        // avc420_yuv_to_rgb: chroma rows and columns count from the rectangle's halved origin.
        kernel void convert420(Plane Y [[texture(0)]], Plane U [[texture(1)]], Plane V [[texture(2)]],
                               texture2d<float, access::write> desktop [[texture(3)]],
                               constant Pass& p [[buffer(0)]], uint2 id [[thread_position_in_grid]]) {
            const int i = id.x, j = id.y;
            if (i >= p.width || j >= p.height) return;
            const int x = p.left + i, y = p.top + j;
            const int cx = p.left / 2 + i / 2, cy = p.top / 2 + j / 2;
            pixel(desktop, p, x, y, at(Y, x, y), at(U, cx, cy), at(V, cx, cy));
        }

        // LumaToYUV444 (B1-B3): copy Y; repeat each chroma sample over its 2x2 block, rounded up to even size.
        kernel void mergeLuma(Plane Y [[texture(0)]], Plane U [[texture(1)]], Plane V [[texture(2)]],
                              Plane444 Y4 [[texture(3)]], Plane444 U4 [[texture(4)]], Plane444 V4 [[texture(5)]],
                              constant Pass& p [[buffer(0)]], uint2 id [[thread_position_in_grid]]) {
            const int i = id.x, j = id.y;
            if (i >= 2 * ((p.width + 1) / 2) || j >= 2 * ((p.height + 1) / 2)) return;
            const int x = p.left + i, y = p.top + j;
            if (i < p.width && j < p.height) put(Y4, x, y, at(Y, x, y));
            const int cx = p.left / 2 + i / 2, cy = p.top / 2 + j / 2;
            put(U4, x, y, at(U, cx, cy));
            put(V4, x, y, at(V, cx, cy));
        }

        // ChromaV1ToYUV444 B4/B5: auxiliary luma rows alternate in groups of 8 between the odd rows of U and V.
        kernel void mergeChromaV1Rows(Plane Y [[texture(0)]], Plane U [[texture(1)]], Plane V [[texture(2)]],
                                      Plane444 Y4 [[texture(3)]], Plane444 U4 [[texture(4)]], Plane444 V4 [[texture(5)]],
                                      constant Pass& p [[buffer(0)]], uint2 id [[thread_position_in_grid]]) {
            const int i = id.x, j = id.y;
            if (i >= p.width || j >= p.height) return;
            const int phase = j % 16;
            const bool toU = phase < 8;
            const int row = 2 * ((j / 16) * 8 + (toU ? phase : phase - 8)) + 1;
            if (row >= p.height) return;
            const uint value = at(Y, p.left + i, p.top + j);
            if (toU) put(U4, p.left + i, p.top + row, value);
            else put(V4, p.left + i, p.top + row, value);
        }

        // ChromaV1ToYUV444 B6/B7: auxiliary chroma fills the odd columns of the even rows.
        kernel void mergeChromaV1Columns(Plane Y [[texture(0)]], Plane U [[texture(1)]], Plane V [[texture(2)]],
                                         Plane444 Y4 [[texture(3)]], Plane444 U4 [[texture(4)]], Plane444 V4 [[texture(5)]],
                                         constant Pass& p [[buffer(0)]], uint2 id [[thread_position_in_grid]]) {
            const int i = id.x, j = id.y;
            if (i >= p.width / 2 || j >= p.height / 2) return;
            const int x = p.left + 2 * i + 1, y = p.top + 2 * j;
            put(U4, x, y, at(U, p.left / 2 + i, p.top / 2 + j));
            put(V4, x, y, at(V, p.left / 2 + i, p.top / 2 + j));
        }

        // ChromaV2ToYUV444 B4/B5: auxiliary luma fills the odd columns; V starts at half the total width.
        kernel void mergeChromaV2Columns(Plane Y [[texture(0)]], Plane U [[texture(1)]], Plane V [[texture(2)]],
                                         Plane444 Y4 [[texture(3)]], Plane444 U4 [[texture(4)]], Plane444 V4 [[texture(5)]],
                                         constant Pass& p [[buffer(0)]], uint2 id [[thread_position_in_grid]]) {
            const int i = id.x, j = id.y;
            if (i >= (p.width + 1) / 2 || j >= p.height) return;
            const int x = p.left + 2 * i + 1, y = p.top + j;
            put(U4, x, y, at(Y, p.left / 2 + i, y));
            put(V4, x, y, at(Y, p.totalWidth / 2 + p.left / 2 + i, y));
        }

        // ChromaV2ToYUV444 B6-B9: auxiliary chroma fills columns 0 and 2 of every 4 in the odd rows.
        kernel void mergeChromaV2Rows(Plane Y [[texture(0)]], Plane U [[texture(1)]], Plane V [[texture(2)]],
                                      Plane444 Y4 [[texture(3)]], Plane444 U4 [[texture(4)]], Plane444 V4 [[texture(5)]],
                                      constant Pass& p [[buffer(0)]], uint2 id [[thread_position_in_grid]]) {
            const int i = id.x, j = id.y;
            if (i >= (p.width + 3) / 4 || j >= (p.height + 1) / 2) return;
            const int y = p.top + 2 * j + 1, source = j + p.top / 2;
            const int x = p.left + 4 * i, column = p.left / 4 + i, offset = p.totalWidth / 4;
            put(U4, x, y, at(U, column, source));
            put(V4, x, y, at(U, offset + column, source));
            put(U4, x + 2, y, at(V, column, source));
            put(V4, x + 2, y, at(V, offset + column, source));
        }

        // avgUV / CONDITIONAL_CLIP: the top-left sample of a 2x2 block becomes 4*u00 - (u01 + u10 + u11),
        // clamped, unless that differs from u00 by less than 30.
        static int filtered(int u00, int u01, int u10, int u11) {
            const int average = clamp(4 * u00 - (u01 + u10 + u11), 0, 255);
            return abs(average - u00) < 30 ? u00 : average;
        }

        // YUV444ToRGB: 2x2 blocks from the rectangle's origin. A block on a trailing odd row is not filtered.
        kernel void convert444(Plane444 Y4 [[texture(0)]], Plane444 U4 [[texture(1)]], Plane444 V4 [[texture(2)]],
                               texture2d<float, access::write> desktop [[texture(3)]],
                               constant Pass& p [[buffer(0)]], uint2 id [[thread_position_in_grid]]) {
            const int bx = 2 * int(id.x), by = 2 * int(id.y);
            if (bx >= p.width || by >= p.height) return;
            const int x = p.left + bx, y = p.top + by;
            const bool pair = by + 1 < p.height;
            int u00 = at(U4, x, y), v00 = at(V4, x, y);
            const int u01 = at(U4, x + 1, y), v01 = at(V4, x + 1, y);
            if (pair) {
                u00 = filtered(u00, u01, at(U4, x, y + 1), at(U4, x + 1, y + 1));
                v00 = filtered(v00, v01, at(V4, x, y + 1), at(V4, x + 1, y + 1));
            }
            const bool second = bx + 1 < p.width;
            pixel(desktop, p, x, y, at(Y4, x, y), u00, v00);
            if (second) pixel(desktop, p, x + 1, y, at(Y4, x + 1, y), u01, v01);
            if (pair) {
                pixel(desktop, p, x, y + 1, at(Y4, x, y + 1), at(U4, x, y + 1), at(V4, x, y + 1));
                if (second) pixel(desktop, p, x + 1, y + 1, at(Y4, x + 1, y + 1), at(U4, x + 1, y + 1), at(V4, x + 1, y + 1));
            }
        }

        kernel void clearPlane(Plane444 t [[texture(0)]], uint2 id [[thread_position_in_grid]]) {
            if (id.x < t.get_width() && id.y < t.get_height()) t.write(uint4(0), id);
        }

        kernel void clearDesktop(texture2d<float, access::write> t [[texture(0)]], uint2 id [[thread_position_in_grid]]) {
            if (id.x < t.get_width() && id.y < t.get_height()) t.write(float4(0), id);
        }
        """
}
