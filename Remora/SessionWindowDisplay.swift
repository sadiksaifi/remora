import AppKit
import RemoraCore

/// Tracks native window transitions separately from the remote desktop size.
@MainActor
final class SessionWindowDisplay {
    private weak var session: (any RemoteSession)?
    private weak var window: NSWindow?
    private var connected = false
    private var transitioning = false
    var applyingRemoteSize = false

    func attach(_ session: any RemoteSession, to window: NSWindow) {
        self.session = session
        self.window = window
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

    func requestResize() {
        guard connected, !transitioning, !applyingRemoteSize,
              let session, session.supportsDynamicResize, let window,
              !window.inLiveResize, let view = window.contentView else { return }
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
