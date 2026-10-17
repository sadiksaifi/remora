import AppKit
import RemoraCore

/// Requests a Fit to Window desktop size that follows the session's content area,
/// separately from the remote desktop size. Full-screen transitions defer requests until they end.
@MainActor
final class SessionDisplay {
    private weak var session: (any RemoteSession)?
    private weak var view: NSView?
    private var connected = false
    private var transitioning = false

    init(view: NSView) {
        self.view = view
    }

    func attach(_ session: any RemoteSession) {
        self.session = session
        connected = false
    }

    func disconnect() {
        session = nil
        connected = false
    }

    func didConnect() {
        connected = true
        requestResize()
    }

    func willTransition() { transitioning = true }

    func didTransition() {
        transitioning = false
        requestResize()
    }

    /// Requests the content area's size in backing pixels. A hidden tab has no window and requests nothing.
    func requestResize() {
        guard connected, !transitioning, let session, session.supportsDynamicResize,
              let view, let window = view.window, !window.inLiveResize else { return }
        let pixels: NSSize
        if window.styleMask.contains(.fullScreen), let screen = window.screen {
            pixels = NSSize(width: screen.frame.width * window.backingScaleFactor,
                            height: screen.frame.height * window.backingScaleFactor)
        } else {
            pixels = view.convertToBacking(view.bounds).size
        }
        guard pixels.width > 0, pixels.height > 0 else { return }
        session.requestResize(DesktopSize(width: Int(pixels.width.rounded()), height: Int(pixels.height.rounded())),
                              scale: window.backingScaleFactor)
    }
}
