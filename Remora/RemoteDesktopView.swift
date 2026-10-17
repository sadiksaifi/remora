import AppKit
import QuartzCore
import RemoraCore

@MainActor
final class RemoteDesktopView: NSView {
    var input: (any RemoteSession)? {
        get { desktopInput.input }
        set {
            desktopInput.input = newValue
            window?.invalidateCursorRects(for: self)
        }
    }
    func setSessionConnected(_ connected: Bool) { desktopInput.setConnected(connected) }

    var onFocus: (() -> Void)?
    private lazy var desktopInput = RemoteDesktopInput(view: self)
    private var inputTrackingArea: NSTrackingArea?
    private var remoteCursor: RemoteCursor = .systemDefault

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
        desktopInput.focusOut()
        refreshLink?.invalidate()
        refreshLink = nil
        refreshTarget = nil
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
        desktopInput.movedToWindow()
        guard let window else { return }
        window.makeFirstResponder(self)
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

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { desktopInput.becameFirstResponder() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        desktopInput.focusOut()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) { desktopInput.key(event, down: true) }
    override func keyUp(with event: NSEvent) { desktopInput.key(event, down: false) }
    override func flagsChanged(with event: NSEvent) { desktopInput.flagsChanged(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        desktopInput.performKeyEquivalent(event) || super.performKeyEquivalent(with: event)
    }
    override func mouseMoved(with event: NSEvent) { desktopInput.pointer(event) }
    override func mouseDragged(with event: NSEvent) { desktopInput.pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { desktopInput.pointer(event) }
    override func otherMouseDragged(with event: NSEvent) { desktopInput.pointer(event) }
    override func mouseDown(with event: NSEvent) { desktopInput.pointer(event, down: true) }
    override func mouseUp(with event: NSEvent) { desktopInput.pointer(event, down: false) }
    override func rightMouseDown(with event: NSEvent) { desktopInput.pointer(event, down: true) }
    override func rightMouseUp(with event: NSEvent) { desktopInput.pointer(event, down: false) }
    override func otherMouseDown(with event: NSEvent) { desktopInput.pointer(event, down: true) }
    override func otherMouseUp(with event: NSEvent) { desktopInput.pointer(event, down: false) }
    override func scrollWheel(with event: NSEvent) { desktopInput.scrollWheel(event) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let inputTrackingArea { removeTrackingArea(inputTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        inputTrackingArea = area
    }

    func apply(cursor: RemoteCursor) {
        remoteCursor = cursor
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
        let geometry = DesktopGeometry(remoteSize: remoteSize, drawableSize: bounds.size)
        guard input != nil, geometry.contentRect.width > 0 else { return }
        let scale = geometry.contentRect.width / remoteSize.width
        addCursorRect(geometry.contentRect, cursor: remoteCursor.cursor(pointsPerPixel: scale))
    }

    /// Maps this flipped view's points to top-left remote pixel coordinates.
    /// Letterbox bars and the exclusive right/bottom edges return nil. No input is sent.
    func remotePoint(for viewPoint: NSPoint) -> CGPoint? {
        // Work in flipped view points. AppKit's backing conversion can reverse Y
        // for a layer-backed view; the aspect-fit scale cancels the backing scale.
        return DesktopGeometry(remoteSize: remoteSize, drawableSize: bounds.size).remotePoint(
            for: CGPoint(x: viewPoint.x - bounds.minX, y: viewPoint.y - bounds.minY)
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
        window?.invalidateCursorRects(for: self)
    }

    private func refresh() {
        if let size = renderer.present(on: metalLayer, redraw: redrawNeeded) {
            if remoteSize != size {
                remoteSize = size
                window?.invalidateCursorRects(for: self)
            }
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
