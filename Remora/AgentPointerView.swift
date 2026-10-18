import AppKit

/// The ghost pointer: a blue arrow at the agent's last point and a ring that flashes on each click.
/// It is a view above the Metal desktop, so screenshots and recordings, which read the frame, never
/// include it. The Settings switch hides it. It ignores the pointer.
@MainActor
final class AgentPointerView: NSView {
    /// The point in remote pixels from the top left, or nil before the agent points.
    private var remotePoint: CGPoint?
    private let arrow = CAShapeLayer()
    private let ring = CALayer()
    private let ringStrokes = [CAShapeLayer(), CAShapeLayer(), CAShapeLayer()]
    private static let ringDiameter: CGFloat = 30

    var isShown = false { didSet { updateVisibility() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // The arrow from the approved mockup, tip at the origin, about 17 pt tall with its outline.
        let points: [(CGFloat, CGFloat)] = [(0, 0), (0, 15.2), (3.9, 11.5), (6.5, 17.6), (9.2, 16.4), (6.6, 10.5), (12, 10.5)]
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.0 * 13 / 15, y: $0.1 * 13 / 15) })
        path.closeSubpath()
        arrow.path = path
        arrow.lineWidth = 1.5
        arrow.lineJoin = .round
        arrow.shadowOpacity = 0.3
        arrow.shadowRadius = 1.5
        arrow.shadowOffset = CGSize(width: 0, height: 1)
        // A 2 pt blue ring with a thin white halo on both sides.
        let radius = Self.ringDiameter / 2
        for (stroke, (inset, width)) in zip(ringStrokes, [(0.5, 1.0), (2, 2), (3.5, 1)]) {
            stroke.path = CGPath(ellipseIn: CGRect(x: inset, y: inset, width: 2 * (radius - inset), height: 2 * (radius - inset)), transform: nil)
            stroke.fillColor = nil
            stroke.lineWidth = width
            ring.addSublayer(stroke)
        }
        ring.bounds = CGRect(x: 0, y: 0, width: Self.ringDiameter, height: Self.ringDiameter)
        ring.opacity = 0
        layer?.addSublayer(ring)
        layer?.addSublayer(arrow)
        updateColors()
        updateVisibility()
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func move(to point: CGPoint, click: Bool) {
        remotePoint = point
        needsLayout = true
        layoutSubtreeIfNeeded()
        updateVisibility()
        guard click, !arrow.isHidden else { return }
        let flash = CABasicAnimation(keyPath: "opacity")
        flash.fromValue = 0.85
        flash.toValue = 0
        flash.duration = 0.5
        flash.timingFunction = CAMediaTimingFunction(name: .easeIn)
        ring.add(flash, forKey: "flash")
    }

    override func layout() {
        super.layout()
        guard let desktop = superview as? RemoteDesktopView, let remotePoint, desktop.remoteSize.width > 0 else { return }
        let screen = desktop.screenRect
        let scale = screen.width / desktop.remoteSize.width
        let point = CGPoint(x: screen.minX + (remotePoint.x + 0.5) * scale, y: screen.minY + (remotePoint.y + 0.5) * scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrow.position = point
        ring.position = point
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            arrow.fillColor = NSColor.systemBlue.cgColor
            arrow.strokeColor = NSColor.white.cgColor
            ringStrokes[0].strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
            ringStrokes[1].strokeColor = NSColor.systemBlue.cgColor
            ringStrokes[2].strokeColor = NSColor.white.withAlphaComponent(0.6).cgColor
        }
    }

    private func updateVisibility() {
        let visible = isShown && remotePoint != nil &&
            UserDefaults.standard.object(forKey: AppSettings.showAgentPointerKey) as? Bool ?? true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrow.isHidden = !visible
        ring.isHidden = !visible
        if !visible { ring.removeAnimation(forKey: "flash") }
        CATransaction.commit()
    }

    @objc private func defaultsChanged() { updateVisibility() }
}
