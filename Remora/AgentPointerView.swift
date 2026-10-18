import AppKit
import QuartzCore
import RemoraCore
import SwiftUI

/// Screen feedback over the desktop: the key press glass capsule at the shared layout and placement,
/// and above it the agent cursor. The recorder draws its own renditions of both from the same state.
@MainActor
final class AgentPointerView: NSView {
    private let state: SessionOverlayState
    private var observer: UUID?
    private let keyPress = NSHostingView(rootView: KeyPressCapsule(pill: nil))
    private var keyPressShown = false
    private let cursor = AgentCursorView()

    init(state: SessionOverlayState, frame: NSRect) {
        self.state = state
        super.init(frame: frame)
        keyPress.sizingOptions = []
        keyPress.alphaValue = 0
        addSubview(keyPress)
        addSubview(cursor)
        cursor.state = state
        state.setDarkAppearance(effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        observer = state.addObserver { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }
    }

    required init?(coder: NSCoder) { fatalError("Use init(state:frame:)") }
    isolated deinit { if let observer { state.removeObserver(observer) } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        update()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        state.setDarkAppearance(effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    /// The capsule fades with the recording's fade, which starts 0.25 seconds before the pill expires.
    private func update() {
        guard let desktop = superview as? RemoteDesktopView else { return }
        cursor.desktop = (desktop.screenRect, desktop.remoteSize)
        cursor.wake()
        let snapshot = state.snapshot()
        guard snapshot.keyText != nil else {
            keyPress.rootView = KeyPressCapsule(pill: nil)
            keyPress.alphaValue = 0
            keyPressShown = false
            return
        }
        guard desktop.remoteSize.width > 0 else { return }
        let screen = desktop.screenRect
        let scale = screen.width / desktop.remoteSize.width
        guard scale > 0 else { return }
        if let (pill, frame) = KeyPressPill.placed(snapshot, desktop: desktop.remoteSize, pointsPerPixel: scale) {
            if keyPress.rootView.pill != pill { keyPress.rootView = KeyPressCapsule(pill: pill) }
            keyPress.frame = frame.offsetBy(dx: screen.minX, dy: screen.minY)
        }
        let shown = snapshot.keyOpacity >= 1
        guard shown != keyPressShown else { return }
        keyPressShown = shown
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; keyPress.animator().alphaValue = shown ? 1 : 0 }
    }
}

/// The agent cursor in Core Animation layers, clipped to the drawn desktop. One spec point is one view point
/// at any desktop scale. The view only reads the shared model; control state alone sets the cursor's visibility.
@MainActor
private final class AgentCursorView: NSView {
    var state: SessionOverlayState?
    /// The drawn desktop in the parent's points, and the remote size in pixels.
    var desktop: (rect: CGRect, size: CGSize) = (.zero, .zero) {
        didSet {
            guard desktop != oldValue else { return }
            frame = desktop.rect
            if displayLink == nil { render(at: ProcessInfo.processInfo.systemUptime) }
        }
    }

    private let cursorLayer = CALayer()
    private let haloLayer = radialGradient(CursorStyle.fog, CursorStyle.fogStops)
    private let liftLayer = radialGradient(CGColor(gray: 1, alpha: 1), CursorStyle.liftStops)
    private let glyphLayer = CAShapeLayer()
    private var displayLink: CADisplayLink?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.masksToBounds = true
        let path = CursorGlyph.path()
        glyphLayer.path = path
        // A layer filter renders the layer's bounds, so they enclose the outline and its stroke.
        glyphLayer.bounds = path.boundingBoxOfPath.insetBy(dx: -CursorStyle.strokeWidth, dy: -CursorStyle.strokeWidth)
        glyphLayer.anchorPoint = CGPoint(x: -glyphLayer.bounds.minX / glyphLayer.bounds.width,
                                         y: -glyphLayer.bounds.minY / glyphLayer.bounds.height)
        glyphLayer.strokeColor = CursorStyle.stroke
        glyphLayer.lineWidth = CursorStyle.strokeWidth
        glyphLayer.lineJoin = .round
        for sublayer in [haloLayer, liftLayer, glyphLayer] { cursorLayer.addSublayer(sublayer) }
        cursorLayer.isHidden = true
        layer?.addSublayer(cursorLayer)
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        NotificationCenter.default.removeObserver(self)
        stop()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowStateChanged), name: name, object: window)
        }
        updateContentsScale()
        wake()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    @objc private func windowStateChanged() { wake() }

    /// Starts the display link when there is something to show; the link stops itself once the frame settles.
    func wake() {
        guard isPresentable, state?.snapshot().showAgentPointer == true else {
            cursorLayer.isHidden = true
            stop()
            return
        }
        guard displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Hidden tabs leave the window, and covered or minimized windows show nothing.
    private var isPresentable: Bool {
        guard let window, window.occlusionState.contains(.visible), !window.isMiniaturized,
              desktop.size.width > 0, desktop.rect.width > 0 else { return false }
        return true
    }

    @objc private func step(_ link: CADisplayLink) {
        let settled = render(at: link.timestamp)
        if settled || !isPresentable { stop() }
    }

    /// Applies the pose at `time` and returns true when nothing will change until the state notifies again.
    @discardableResult
    private func render(at time: TimeInterval) -> Bool {
        guard let state, isPresentable else { cursorLayer.isHidden = true; return true }
        let snapshot = state.snapshot(at: time)
        guard snapshot.showAgentPointer else { cursorLayer.isHidden = true; return true }
        guard let frame = snapshot.agentCursor, frame.pose.opacity > 0.001 else {
            cursorLayer.isHidden = true
            return snapshot.agentCursor?.isSettled ?? true
        }
        apply(frame)
        return frame.isSettled
    }

    private func apply(_ frame: AgentCursorFrame) {
        let pose = frame.pose
        let pointsPerPixel = desktop.rect.width / desktop.size.width
        // Anchor on the tip, then lay out the artwork in spec points: one spec point per view point.
        let tip = CGPoint(x: pose.hotspot.x * pointsPerPixel, y: pose.hotspot.y * pointsPerPixel)
        func offset(_ point: CGPoint) -> CGPoint {
            CGPoint(x: tip.x + (point.x - pose.hotspot.x) / frame.unit, y: tip.y + (point.y - pose.hotspot.y) / frame.unit)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.isHidden = false
        cursorLayer.opacity = Float(pose.opacity)
        glyphLayer.position = offset(pose.center)
        glyphLayer.setAffineTransform(
            CGAffineTransform(rotationAngle: pose.rotation).scaledBy(x: pose.scaleAcross, y: pose.scaleAlong))
        glyphLayer.fillColor = frame.fill
        let blur = pose.blurRadius / frame.unit
        if blur > 0.05, let filter = CIFilter(name: "CIGaussianBlur") {
            filter.setValue(blur, forKey: kCIInputRadiusKey)
            glyphLayer.filters = [filter]
        } else if glyphLayer.filters != nil {
            glyphLayer.filters = nil
        }
        let halo = offset(pose.haloCenter)
        let haloTransform = CGAffineTransform(scaleX: pose.haloScale, y: pose.haloScale)
        for layer in [haloLayer, liftLayer] {
            layer.position = halo
            layer.setAffineTransform(haloTransform)
        }
        CATransaction.commit()
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [cursorLayer, haloLayer, liftLayer, glyphLayer] { layer.contentsScale = scale }
        CATransaction.commit()
    }
}

/// A radial gradient over a square whose half-width is the last stop's radius in spec points.
private func radialGradient(_ color: CGColor, _ stops: [(radius: Double, alpha: Double)]) -> CAGradientLayer {
    let radius = stops.last!.radius
    let gradient = CAGradientLayer()
    gradient.type = .radial
    gradient.colors = stops.map { color.copy(alpha: $0.alpha)! }
    gradient.locations = stops.map { NSNumber(value: $0.radius / radius) }
    gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
    gradient.endPoint = CGPoint(x: 1, y: 1)
    gradient.bounds = CGRect(x: 0, y: 0, width: 2 * radius, height: 2 * radius)
    return gradient
}
