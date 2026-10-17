import AppKit

/// Remora's application object. It hands every event to a router before AppKit dispatches it.
/// AppKit runs local event monitors and its own text and suggestions handling inside that dispatch,
/// so the router sees each event before any of them and can act after them.
@objc(RemoraApplication)
final class RemoraApplication: NSApplication {
    /// Receives each event and a closure that runs AppKit's dispatch. Skipping the closure consumes the event.
    var routeEvent: ((NSEvent, () -> Void) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        guard let routeEvent else { return super.sendEvent(event) }
        routeEvent(event) { super.sendEvent(event) }
    }
}
