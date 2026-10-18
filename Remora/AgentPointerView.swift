import AppKit
import RemoraCore

/// Screen feedback uses the same desktop-pixel artwork as the movie compositor.
@MainActor
final class AgentPointerView: NSView {
    private let state: SessionOverlayState
    private let drawing = SessionOverlayDrawing()
    private var observer: UUID?

    init(state: SessionOverlayState, frame: NSRect) {
        self.state = state
        super.init(frame: frame)
        observer = state.addObserver { [weak self] _ in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }
    }

    required init?(coder: NSCoder) { fatalError("Use init(state:frame:)") }
    isolated deinit { if let observer { state.removeObserver(observer) } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let desktop = superview as? RemoteDesktopView, desktop.remoteSize.width > 0,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let screen = desktop.screenRect
        let scale = screen.width / desktop.remoteSize.width
        context.saveGState()
        context.clip(to: screen)
        context.translateBy(x: screen.minX, y: screen.minY)
        context.scaleBy(x: scale, y: scale)
        for sprite in drawing.sprites(state.snapshot(), desktop: desktop.remoteSize, recording: false) {
            context.saveGState()
            context.setAlpha(sprite.opacity)
            context.translateBy(x: sprite.rect.minX, y: sprite.rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(sprite.image, in: CGRect(origin: .zero, size: sprite.rect.size))
            context.restoreGState()
        }
        context.restoreGState()
    }
}
