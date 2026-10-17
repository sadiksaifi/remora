#if DEBUG
import AppKit
import QuartzCore
import Synchronization

/// A borrowed CPU framebuffer, driven on a worker thread without a session backend.
@MainActor
final class RendererDemo: NSWindowController, NSWindowDelegate {
    private let desktop: RemoteDesktopView
    private let producer: Producer
    private var metricsTimer: Timer?
    private var previousStatistics = FrameRenderer.Statistics()
    private var previousTime = CACurrentMediaTime()
    private let pauseButton = NSButton(title: "Pause damage", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "2560 × 1440 remote pixels")

    init(renderer: FrameRenderer) {
        desktop = RemoteDesktopView(renderer: renderer)
        producer = Producer(renderer: renderer)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Renderer demo"
        window.minSize = NSSize(width: 600, height: 400)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        pauseButton.target = self
        pauseButton.action = #selector(toggleDamage(_:))
        let native = NSButton(title: "1:1 pixels", target: self, action: #selector(nativeSize(_:)))
        let fit = NSButton(title: "Aspect fit", target: self, action: #selector(fitSize(_:)))
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        let controls = NSStackView(views: [pauseButton, native, fit, status])
        controls.spacing = 12
        let content = NSView()
        window.contentView = content
        for view in [desktop, controls] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            desktop.topAnchor.constraint(equalTo: content.topAnchor, constant: 44),
            desktop.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            desktop.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            desktop.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.center()
        let producer = producer
        let worker = Thread { producer.run() }
        worker.name = "Renderer demo producer"
        worker.qualityOfService = .userInteractive
        worker.start()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMetrics() }
        }
        RunLoop.main.add(timer, forMode: .common)
        metricsTimer = timer
    }

    required init?(coder: NSCoder) { fatalError("Use init(renderer:)") }

    isolated deinit {
        producer.stop()
        metricsTimer?.invalidate()
    }

    func stop() {
        producer.stop()
        metricsTimer?.invalidate()
        metricsTimer = nil
    }

    func windowWillClose(_ notification: Notification) { stop() }

    @objc private func toggleDamage(_ sender: Any?) {
        let paused = producer.togglePause()
        pauseButton.title = paused ? "Resume damage" : "Pause damage"
    }

    @objc private func nativeSize(_ sender: Any?) {
        guard let window else { return }
        let scale = window.backingScaleFactor
        window.setContentSize(NSSize(width: 2560 / scale, height: 1440 / scale + 44))
        window.center()
    }

    @objc private func fitSize(_ sender: Any?) {
        window?.setContentSize(NSSize(width: 1000, height: 800))
        window?.center()
    }

    private func updateMetrics() {
        let now = CACurrentMediaTime()
        let elapsed = now - previousTime
        let render = desktop.renderer.statistics
        let samples = producer.samples
        let presents = Double(render.presentedFrames - previousStatistics.presentedFrames) / elapsed
        let submitted = render.submittedFrames - previousStatistics.submittedFrames
        let gpuMilliseconds = (render.gpuSeconds - previousStatistics.gpuSeconds) * 1000
        let small = samples.smallCount > 0 ? samples.smallSeconds * 1_000_000 / Double(samples.smallCount) : 0
        let full = samples.fullCount > 0 ? samples.fullSeconds * 1_000_000 / Double(samples.fullCount) : 0
        window?.title = String(format: "Renderer demo | %.1f presents/s | ingest %.1f µs", presents, samples.averageMicroseconds)
        let geometry = DesktopGeometry(remoteSize: desktop.remoteSize, drawableSize: desktop.convertToBacking(desktop.bounds).size)
        status.stringValue = String(format: "small %.1f µs · full %.1f µs · %@", small, full, geometry.isPixelExact ? "1:1 nearest" : "aspect fit linear")
        NSLog("RendererDemo paused=%@ presents/s=%.2f submitted=%llu gpu_ms=%.3f small_us=%.3f full_us=%.3f small_n=%llu full_n=%llu total_submitted=%llu failure=%@",
              samples.paused.description, presents, submitted, gpuMilliseconds, small, full, samples.smallCount, samples.fullCount,
              render.submittedFrames, render.lastFailure?.localizedDescription ?? "none")
        previousStatistics = render
        previousTime = now
    }

    private final class Producer: Sendable {
        struct Samples: Sendable {
            var stopped = false
            var paused = false
            var smallCount: UInt64 = 0
            var fullCount: UInt64 = 0
            var smallSeconds = 0.0
            var fullSeconds = 0.0
            var averageMicroseconds: Double {
                let count = smallCount + fullCount
                return count > 0 ? (smallSeconds + fullSeconds) * 1_000_000 / Double(count) : 0
            }
        }

        private let renderer: FrameRenderer
        private let state = Mutex(Samples())
        var samples: Samples { state.withLock { $0 } }

        init(renderer: FrameRenderer) { self.renderer = renderer }
        func stop() { state.withLock { $0.stopped = true } }
        func togglePause() -> Bool { state.withLock { $0.paused.toggle(); return $0.paused } }

        func run() {
            let width = 2560
            let height = 1440
            let stride = width * 4
            let pixels = UnsafeMutableRawPointer.allocate(byteCount: stride * height, alignment: 256)
            defer { pixels.deallocate() }
            var frame = 0
            var previous = DirtyRect(x: 0, y: 0, width: 0, height: 0)
            var deadline = CACurrentMediaTime()
            while true {
                let control = samples
                if control.stopped { return }
                if !control.paused {
                    let rectangle = DirtyRect(x: 100 + (frame * 9) % 2200, y: 160 + (frame * 3) % 1040, width: 160, height: 96)
                    let full = frame % 60 == 0
                    if full {
                        paintBackground(pixels, rectangle: DirtyRect(x: 0, y: 0, width: width, height: height), stride: stride)
                        // Single-pixel vertical stripes reveal blur at native resolution.
                        for x in 64..<576 {
                            fill(pixels, rectangle: DirtyRect(x: x, y: 64, width: 1, height: 64), stride: stride,
                                 color: x.isMultiple(of: 2) ? 0x00FFFFFF : 0)
                        }
                    } else {
                        paintBackground(pixels, rectangle: previous, stride: stride)
                    }
                    fill(pixels, rectangle: rectangle, stride: stride, color: 0x00F5A623)
                    let dirty = full ? [DirtyRect(x: 0, y: 0, width: width, height: height)] : [previous, rectangle]
                    let start = CACurrentMediaTime()
                    renderer.ingest(pixels: pixels, width: width, height: height, bytesPerRow: stride, dirty: dirty)
                    let duration = CACurrentMediaTime() - start
                    state.withLock {
                        if full { $0.fullCount += 1; $0.fullSeconds += duration }
                        else { $0.smallCount += 1; $0.smallSeconds += duration }
                    }
                    previous = rectangle
                    frame += 1
                }
                deadline += 1.0 / 60
                let remaining = deadline - CACurrentMediaTime()
                if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
                else { deadline = CACurrentMediaTime() }
            }
        }

        private func paintBackground(_ pixels: UnsafeMutableRawPointer, rectangle: DirtyRect, stride: Int) {
            for y in rectangle.y..<(rectangle.y + rectangle.height) {
                var color: UInt32 = (y / 90).isMultiple(of: 2) ? 0x001B2838 : 0x00233346
                if y < 16 { color = 0x00E24A4A }
                if y >= 1424 { color = 0x004A80E2 }
                memset_pattern4(pixels + y * stride + rectangle.x * 4, &color, rectangle.width * 4)
            }
        }

        private func fill(_ pixels: UnsafeMutableRawPointer, rectangle: DirtyRect, stride: Int, color: UInt32) {
            var color = color
            for y in rectangle.y..<(rectangle.y + rectangle.height) {
                memset_pattern4(pixels + y * stride + rectangle.x * 4, &color, rectangle.width * 4)
            }
        }
    }
}
#endif
