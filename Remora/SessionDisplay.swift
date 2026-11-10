import AppKit
import RemoraCore

/// Requests a Fit to Window desktop size that follows the session's content area,
/// separately from the remote desktop size. Full-screen transitions defer requests until they end.
/// Asks the server to pause desktop updates while the content area can't be seen: a hidden tab,
/// a minimized window, or a fully covered window. A standard VNC server keeps sending them.
@MainActor
final class SessionDisplay {
    private weak var session: (any RemoteSession)?
    private weak var view: NSView?
    private var connected = false
    private var transitioning = false
    private var visible = false
    private var recording = false
    private var commandLineDemand = 0
    var followsWindow = true
    var onScaleChange: ((Double) -> Void)?

    @discardableResult
    func addCommandLineDemand() -> Bool {
        let resumed = !visible && !recording && commandLineDemand == 0
        commandLineDemand += 1
        session?.setDisplayUpdatesEnabled(visible || recording || commandLineDemand > 0)
        return resumed
    }

    func removeCommandLineDemand() {
        commandLineDemand = max(0, commandLineDemand - 1)
        session?.setDisplayUpdatesEnabled(visible || recording || commandLineDemand > 0)
    }

    func setRecording(_ active: Bool) {
        recording = active
        session?.setDisplayUpdatesEnabled(visible || recording || commandLineDemand > 0)
    }

    init(view: NSView) {
        self.view = view
    }

    func attach(_ session: any RemoteSession) {
        self.session = session
        connected = false
        visible = isVisible
        session.setDisplayUpdatesEnabled(visible || recording || commandLineDemand > 0)
    }

    /// Call when the view joins or leaves a window, or the window's occlusion changes.
    func visibilityChanged() {
        let visible = isVisible
        guard visible != self.visible else { return }
        self.visible = visible
        session?.setDisplayUpdatesEnabled(visible || recording || commandLineDemand > 0)
    }

    private var isVisible: Bool {
        guard let window = view?.window else { return false }
        return window.occlusionState.contains(.visible) && !window.isMiniaturized
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
        guard followsWindow, connected, !transitioning, let session, session.supportsDynamicResize,
              let view, let window = view.window, !window.inLiveResize else { return }
        let scale = window.backingScaleFactor
        let pixels: NSSize
        if window.styleMask.contains(.fullScreen), let screen = window.screen {
            pixels = NSSize(width: screen.frame.width * scale,
                            height: screen.frame.height * scale)
        } else {
            pixels = view.convertToBacking(view.bounds).size
        }
        guard pixels.width > 0, pixels.height > 0 else { return }
        onScaleChange?(scale)
        session.requestResize(DesktopSize(width: Int(pixels.width.rounded()), height: Int(pixels.height.rounded())),
                              scale: scale)
    }
}
