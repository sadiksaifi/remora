import AppKit
import RemoraCore
import SwiftUI

/// Screen feedback: pointer artwork shared with the movie compositor, and the key press glass capsule
/// at the shared layout and placement. The recorder draws its own rendition of the same capsule.
@MainActor
final class AgentPointerView: NSView {
    private let state: SessionOverlayState
    private let drawing = SessionOverlayDrawing()
    private var observer: UUID?
    private let keyPress = NSHostingView(rootView: KeyPressCapsule(pill: nil))
    private var keyPressShown = false

    init(state: SessionOverlayState, frame: NSRect) {
        self.state = state
        super.init(frame: frame)
        keyPress.sizingOptions = []
        keyPress.alphaValue = 0
        addSubview(keyPress)
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
        needsDisplay = true
        guard let desktop = superview as? RemoteDesktopView, desktop.remoteSize.width > 0 else { return }
        let snapshot = state.snapshot()
        let screen = desktop.screenRect
        let scale = screen.width / desktop.remoteSize.width
        if let (pill, frame) = KeyPressPill.placed(snapshot, desktop: desktop.remoteSize) {
            let shown = KeyPressPill(text: snapshot.keyText, isText: snapshot.keyIsText, scale: pill.scale * scale)
            if keyPress.rootView.pill != shown { keyPress.rootView = KeyPressCapsule(pill: shown) }
            keyPress.frame = CGRect(x: screen.minX + frame.minX * scale, y: screen.minY + frame.minY * scale,
                                    width: frame.width * scale, height: frame.height * scale)
        }
        let shown = snapshot.keyText != nil && snapshot.keyOpacity >= 1
        guard shown != keyPressShown else { return }
        keyPressShown = shown
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; keyPress.animator().alphaValue = shown ? 1 : 0 }
    }

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
