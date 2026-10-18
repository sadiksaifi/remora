import Foundation
import CoreGraphics

/// One session's input feedback. The transport, AppKit, and recorder can access it concurrently.
public final class SessionOverlayState: @unchecked Sendable {
    public struct Click: Sendable {
        public let point: CGPoint
        public let source: InputSource
        public let time: TimeInterval
    }
    public struct Snapshot: Sendable {
        /// Reading a snapshot advances this shared cursor monotonically to `time`.
        public let agentCursor: AgentCursorFrame?
        public let point: CGPoint?
        public let owner: InputSource
        public let cursor: CGImage?
        public let hotspot: CGPoint
        public let clicks: [Click]
        public let keyText: String?
        public let keyIsText: Bool
        public let keyOpacity: Double
        /// A multiple of the pill's standard size.
        public let keySize: Double
        /// The screen's appearance, which the recorded glass follows.
        public let dark: Bool
        public let showPointerInRecordings: Bool
        public let showAgentPointer: Bool
        public let scale: Double
        public let time: TimeInterval
    }

    private let lock = NSLock()
    private var agentCursor: CursorMotion?
    private var agentUnit = 1.0
    private var agentPoint: CGPoint?
    private var desktopSize = CGSize.zero
    private var agentVisible = false
    private var agentBusy = false
    private var idleSince: TimeInterval?
    private var reduceMotion = false
    private var point: CGPoint?
    private var owner: InputSource = .human
    private var cursor: CGImage?
    private var hotspot = CGPoint.zero
    private var clicks: [Click] = []
    private var humanButtons: PointerButtons = []
    private var agentButtons: PointerButtons = []
    private var humanKeys = KeyPressDisplay()
    private var agentKeys = KeyPressDisplay()
    private var press: KeyPressDisplay.Press?
    private var repeats = 1
    private var keyTime: TimeInterval = -.infinity
    private var showPointer = true
    private var showKeys = false
    private var showAgent = false
    private var keySize = 1.0
    private var dark = false
    private var scale = 1.0
    private var observers: [UUID: @Sendable (TimeInterval) -> Void] = [:]
    private var timer: DispatchSourceTimer?

    public init() {}
    deinit { timer?.cancel() }

    public func reset() {
        change {
            point = nil
            agentCursor = nil
            agentPoint = nil
            desktopSize = .zero
            agentVisible = false
            agentBusy = false
            idleSince = nil
            clicks = []
            press = nil
            humanKeys = KeyPressDisplay(); agentKeys = KeyPressDisplay()
            humanButtons = []; agentButtons = []
        }
    }

    public func configure(showPointerInRecordings: Bool, showKeyPresses: Bool, showAgentPointer: Bool, scale: Double,
                          keyPressSize: Double = 1) {
        change {
            keySize = min(KeyPressPill.sizes.upperBound, max(KeyPressPill.sizes.lowerBound, keyPressSize))
            showPointer = showPointerInRecordings
            showKeys = showKeyPresses
            showAgent = showAgentPointer
            let oldUnit = cursorUnit
            self.scale = max(1, scale)
            if oldUnit != cursorUnit { replaceCursorGeometry() }
            if !showKeys { press = nil }
        }
    }

    private var cursorUnit: Double { sessionOverlayUnit(scale: scale, desktopHeight: desktopSize.height) }

    public func setDesktopSize(_ size: CGSize) {
        change {
            guard desktopSize != size else { return }
            desktopSize = size
            replaceCursorGeometry()
        }
    }

    public func setReduceMotion(_ enabled: Bool) {
        change { reduceMotion = enabled; agentCursor?.reduceMotion = enabled }
    }

    /// Control ownership alone sets visibility. Screen/recording settings only select outputs.
    public func setAgentCursorVisible(_ visible: Bool) {
        change {
            guard agentVisible != visible else { return }
            agentVisible = visible
            if agentCursor == nil { replaceCursorGeometry() }
            if !visible, let at = agentCursor?.pose.hotspot { agentCursor?.follow(to: at) }
            agentCursor?.isVisible = visible
            updateThinkingWindow()
        }
    }

    public func setAgentCursorBusy(_ busy: Bool) {
        change {
            agentBusy = busy
            idleSince = busy ? nil : ProcessInfo.processInfo.systemUptime
            if !busy { agentCursor?.release() }
            updateThinkingWindow()
        }
    }

    /// Returns the remaining fixed-grid travel time. Points are remote desktop pixels.
    @discardableResult
    public func moveAgentCursor(to point: CGPoint, animated: Bool) -> TimeInterval {
        var delay = 0.0
        change {
            agentPoint = point
            if agentCursor == nil { replaceCursorGeometry() }
            let target = CGPoint(x: point.x / cursorUnit, y: point.y / cursorUnit)
            if animated { agentCursor?.move(to: target) }
            else { agentCursor?.place(at: target) }
            delay = agentCursor?.arrivalDelay ?? 0
        }
        return delay
    }

    public func followAgentCursor(to point: CGPoint) {
        change {
            agentPoint = point
            agentCursor?.follow(to: CGPoint(x: point.x / cursorUnit, y: point.y / cursorUnit))
        }
    }

    public func pressAgentCursor(depth: Double, animated: Bool) {
        change {
            agentCursor?.pressDown(depth: depth)
            // Unpresented commands do not animate or wait for a press.
            if !animated { agentCursor?.release() }
        }
    }

    public func releaseAgentCursor() { change { agentCursor?.release() } }

    private func updateThinkingWindow() {
        agentCursor?.thinkingWindow = agentVisible && !agentBusy ? idleSince.map { ($0 + 0.5)..<($0 + 30) } : nil
    }

    private func replaceCursorGeometry() {
        guard desktopSize.width > 0, desktopSize.height > 0, agentCursor != nil || agentVisible else { return }
        let pixel = agentCursor.map { CGPoint(x: $0.pose.hotspot.x * agentUnit, y: $0.pose.hotspot.y * agentUnit) }
        let at = pixel ?? agentPoint ?? point ?? CGPoint(x: desktopSize.width / 2, y: desktopSize.height / 2)
        let target = CGPoint(x: at.x / cursorUnit, y: at.y / cursorUnit)
        let bounds = CGRect(x: 0, y: 0, width: desktopSize.width / cursorUnit, height: desktopSize.height / cursorUnit)
        if agentCursor != nil {
            agentCursor?.bounds = bounds
            agentCursor?.place(at: target)
        } else {
            agentCursor = CursorMotion(hotspot: target, bounds: bounds, time: ProcessInfo.processInfo.systemUptime)
        }
        agentCursor?.reduceMotion = reduceMotion
        agentCursor?.isVisible = agentVisible
        agentUnit = cursorUnit
        updateThinkingWindow()
    }

    public func setDarkAppearance(_ dark: Bool) { change { self.dark = dark } }

    public func setCursor(_ image: CGImage?, hotspot: CGPoint) {
        change { cursor = image; self.hotspot = hotspot }
    }

    public func receive(_ source: InputSource, _ event: SessionInputFeedback) {
        change {
            let now = ProcessInfo.processInfo.systemUptime
            switch event {
            case .pointer(let position, let buttons):
                point = CGPoint(x: Int(position.x), y: Int(position.y))
                owner = source
                let previous = source == .human ? humanButtons : agentButtons
                if source == .human, !buttons.subtracting(previous).isEmpty {
                    clicks.append(Click(point: point!, source: source, time: now))
                    clicks = Array(clicks.suffix(8))
                }
                if source == .human { humanButtons = buttons } else { agentButtons = buttons }
            case .key(let scancode, let down, let characters):
                let next = source == .human
                    ? humanKeys.key(scancode: scancode, down: down, characters: characters)
                    : agentKeys.key(scancode: scancode, down: down, characters: characters)
                if let next { append(next, at: now) }
            case .text(let text): append(KeyPressDisplay.text(text), at: now)
            case .release:
                if source == .human { humanKeys = KeyPressDisplay(); humanButtons = [] }
                else { agentKeys = KeyPressDisplay(); agentButtons = [] }
            }
        }
    }

    public func snapshot(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Snapshot {
        lock.withLock {
            agentCursor?.advance(to: time)
            let age = time - keyTime
            let text = showKeys && age < 1.5 ? press.map { $0.text + (repeats > 1 ? " ×\(repeats)" : "") } : nil
            return Snapshot(agentCursor: agentCursor.map { AgentCursorFrame(pose: $0.pose, unit: cursorUnit, isSettled: $0.isSettled) }, point: point, owner: owner, cursor: cursor, hotspot: hotspot,
                clicks: clicks.filter { time - $0.time < 0.5 }, keyText: text, keyIsText: press?.isText ?? false,
                keyOpacity: min(1, max(0, (1.5 - age) / 0.25)), keySize: keySize, dark: dark,
                showPointerInRecordings: showPointer, showAgentPointer: showAgent, scale: scale, time: time)
        }
    }

    /// Observers enqueue drawing work; they must not call back into this object synchronously.
    public func addObserver(_ observer: @escaping @Sendable (TimeInterval) -> Void) -> UUID {
        lock.withLock {
            let id = UUID()
            observers[id] = observer
            observer(ProcessInfo.processInfo.systemUptime)
            return id
        }
    }

    public func removeObserver(_ id: UUID) { _ = lock.withLock { observers.removeValue(forKey: id) } }

    private func append(_ next: KeyPressDisplay.Press, at time: TimeInterval) {
        guard showKeys else { return }
        if time - keyTime < 1.5, let previous = press {
            if previous.isText && next.isText {
                press = .init(text: String((previous.text + next.text).suffix(32)), isText: true)
                repeats = 1
            } else if previous == next && !next.isText { repeats += 1 }
            else { press = next; repeats = 1 }
        } else { press = next; repeats = 1 }
        keyTime = time
    }

    private func change(_ body: () -> Void) {
        lock.withLock {
            agentCursor?.advance(to: ProcessInfo.processInfo.systemUptime)
            body()
            tick()
            if timer == nil, needsTicks {
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
                timer.schedule(deadline: .now() + 1.0 / 60, repeating: 1.0 / 60)
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    self.lock.withLock { self.tick() }
                }
                self.timer = timer
                timer.resume()
            }
        }
    }

    private var needsTicks: Bool {
        !clicks.isEmpty || (showKeys && press != nil) || agentCursor?.isSettled == false
            || (agentVisible && !agentBusy && !reduceMotion && idleSince.map { ProcessInfo.processInfo.systemUptime < $0 + 30 } == true)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        agentCursor?.advance(to: now)
        clicks.removeAll { now - $0.time >= 0.5 }
        if now - keyTime >= 1.5 { press = nil }
        for observer in observers.values { observer(now) }
        if !needsTicks { timer?.cancel(); timer = nil }
    }
}
