import AppKit
import QuartzCore

@MainActor
final class RemoteDesktopView: NSView {
    let renderer: FrameRenderer
    private let metalLayer = CAMetalLayer()
    private var refreshLink: CADisplayLink?
    private var refreshTarget: RefreshTarget?
    private var redrawNeeded = true
    private(set) var remoteSize = CGSize.zero

    init(renderer: FrameRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.isOpaque = true
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.presentsWithTransaction = false
        metalLayer.displaySyncEnabled = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("Use init(renderer:)") }

    isolated deinit { refreshLink?.invalidate() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func makeBackingLayer() -> CALayer { metalLayer }

    override func updateLayer() { redrawNeeded = true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        refreshLink?.invalidate()
        refreshLink = nil
        refreshTarget = nil
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
        guard window != nil else { return }
        let target = RefreshTarget(view: self)
        let link = displayLink(target: target, selector: #selector(RefreshTarget.refresh(_:)))
        link.add(to: .main, forMode: .common)
        refreshTarget = target
        refreshLink = link
        redrawNeeded = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    /// Maps this flipped view's points to top-left remote pixel coordinates.
    /// Letterbox bars and the exclusive right/bottom edges return nil. No input is sent.
    func remotePoint(for viewPoint: NSPoint) -> CGPoint? {
        let backingBounds = convertToBacking(bounds)
        let backingPoint = convertToBacking(viewPoint)
        return DesktopGeometry(remoteSize: remoteSize, drawableSize: backingBounds.size).remotePoint(
            for: CGPoint(x: backingPoint.x - backingBounds.minX, y: backingPoint.y - backingBounds.minY)
        )
    }

    private func updateDrawableSize() {
        let size = convertToBacking(bounds).size
        let scale = window?.backingScaleFactor ?? 1
        guard size != metalLayer.drawableSize || scale != metalLayer.contentsScale else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = size
        CATransaction.commit()
        redrawNeeded = true
    }

    private func refresh() {
        if let size = renderer.present(on: metalLayer, redraw: redrawNeeded) {
            remoteSize = size
            redrawNeeded = false
        }
    }

    @MainActor
    private final class RefreshTarget: NSObject {
        weak var view: RemoteDesktopView?
        init(view: RemoteDesktopView) { self.view = view }
        @objc func refresh(_ link: CADisplayLink) { view?.refresh() }
    }
}
