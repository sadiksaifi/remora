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
    func sendCtrlAltDelete() { desktopInput.sendCtrlAltDelete() }

    var allowsHumanInput: Bool {
        get { desktopInput.allowsHumanInput }
        set { desktopInput.allowsHumanInput = newValue }
    }
    var onHumanInput: ((SessionControl.HumanInput) -> Void)? {
        get { desktopInput.onHumanInput }
        set { desktopInput.onHumanInput = newValue }
    }
    var onFocus: (() -> Void)?
    /// Called when the desktop gains or loses the keyboard: it is first responder of the key window,
    /// the app is active, and the session is connected. System shortcut capture follows the same state.
    var onCaptureChange: ((Bool) -> Void)? {
        get { desktopInput.onCaptureChange }
        set { desktopInput.onCaptureChange = newValue }
    }
    private lazy var desktopInput = RemoteDesktopInput(view: self)
    private var inputTrackingArea: NSTrackingArea?
    private var remoteCursor: RemoteCursor = .systemDefault

    let renderer: FrameRenderer
    private let metalLayer = CAMetalLayer()
    private var refreshLink: CADisplayLink?
    private var refreshTarget: RefreshTarget?
    private var redrawNeeded = true
    private(set) var remoteSize = CGSize.zero

    /// The tab this desktop belongs to, for its accessibility label and identifier.
    var accessibilityTab = (id: UUID(), title: "") {
        didSet {
            setAccessibilityLabel("Remote desktop, \(accessibilityTab.title)")
            setAccessibilityIdentifier("remoteDesktop-\(accessibilityTab.id.uuidString)")
            updateScreenElement()
        }
    }
    /// The session controller's summary of status, keyboard, and recording. A change notifies accessibility clients.
    var accessibilityState = "" {
        didSet {
            guard accessibilityState != oldValue else { return }
            setAccessibilityValue(accessibilityState)
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }
    var isKeyboardCaptured = false
    /// Accessibility asks to capture (true) or release (false) the keyboard through the session controller.
    var onAccessibilityCapture: ((Bool) -> Void)?
    /// The drawn remote screen. Its frame is the area without letterbox bars and its value is the remote
    /// size in pixels as "WIDTHxHEIGHT", so an agent maps a point to remote pixels with standard attributes.
    private lazy var screenElement: NSAccessibilityElement = {
        let element = NSAccessibilityElement()
        element.setAccessibilityParent(self)
        element.setAccessibilityElement(true)
        element.setAccessibilityRole(.image)
        element.setAccessibilityLabel("Remote screen")
        return element
    }()

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
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription("Remote desktop")
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

    /// True while the agent has control. The Settings switch can still hide the pointer.
    var showsAgentPointer = false {
        didSet { agentPointer?.isShown = showsAgentPointer }
    }
    private var agentPointer: AgentPointerView?

    func moveAgentPointer(to remotePoint: CGPoint, click: Bool) {
        if agentPointer == nil {
            let pointer = AgentPointerView(frame: bounds)
            pointer.autoresizingMask = [.width, .height]
            pointer.isShown = showsAgentPointer
            addSubview(pointer)
            agentPointer = pointer
        }
        agentPointer?.move(to: remotePoint, click: click)
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
        updateScreenElement()
    }

    private func refresh() {
        if let size = renderer.present(on: metalLayer, redraw: redrawNeeded) {
            if remoteSize != size {
                remoteSize = size
                agentPointer?.needsLayout = true
                window?.invalidateCursorRects(for: self)
                updateScreenElement()
                NSAccessibility.post(element: screenElement, notification: .valueChanged)
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

// MARK: Accessibility

/// One element for the whole desktop. The remote computer's apps are pixels here, not accessibility
/// elements. Pressing or focusing it captures the keyboard the way a click does, without sending a click.
extension RemoteDesktopView {
    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
    override func setAccessibilityFocused(_ focused: Bool) { onAccessibilityCapture?(focused) }

    override func accessibilityPerformPress() -> Bool {
        onAccessibilityCapture?(true)
        return true
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let captured = isKeyboardCaptured
        return [NSAccessibilityCustomAction(name: captured ? "Release Keyboard Capture" : "Capture Keyboard") { [weak self] in
            self?.onAccessibilityCapture?(!captured)
            return true
        }]
    }

    override func accessibilityChildren() -> [Any]? { (super.accessibilityChildren() ?? []) + [screenElement] }

    override func accessibilityHelp() -> String? {
        var help = "The remote computer's apps are not accessibility elements. Press or focus this desktop to capture the keyboard; Control-Option-Command-Escape releases it. Command acts as the Windows or Super key, Control as Control, and Option as Alt."
        let content = screenRect
        guard content.width > 0 else { return help + " The remote screen has not drawn yet." }
        let scale = content.width / remoteSize.width
        help += " The remote screen is \(Int(remoteSize.width)) by \(Int(remoteSize.height)) pixels, drawn at x \(Self.number(content.minX)), y \(Self.number(content.minY)), \(Self.number(content.width)) by \(Self.number(content.height)) points in this view, at \(Self.number(scale)) points per pixel, from the top left. Remote x = (view x - \(Self.number(content.minX))) / \(Self.number(scale)), and remote y = (view y - \(Self.number(content.minY))) / \(Self.number(scale))."
        return help
    }

    /// The drawn remote screen in this view's flipped points, without letterbox bars.
    var screenRect: CGRect {
        DesktopGeometry(remoteSize: remoteSize, drawableSize: bounds.size).contentRect.offsetBy(dx: bounds.minX, dy: bounds.minY)
    }

    private func updateScreenElement() {
        screenElement.setAccessibilityIdentifier("remoteScreen-\(accessibilityTab.id.uuidString)")
        screenElement.setAccessibilityValue("\(Int(remoteSize.width))x\(Int(remoteSize.height))")
        screenElement.setAccessibilityFrameInParentSpace(screenRect)
    }

    /// Locale-independent, so agents can parse it.
    private static func number(_ value: CGFloat) -> String { String(format: "%g", Double(value)) }
}
