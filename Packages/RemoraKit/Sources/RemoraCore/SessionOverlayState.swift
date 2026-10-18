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
        public let point: CGPoint?
        public let owner: InputSource
        public let cursor: CGImage?
        public let hotspot: CGPoint
        public let clicks: [Click]
        public let keyText: String?
        public let keyOpacity: Double
        public let showPointerInRecordings: Bool
        public let showAgentPointer: Bool
        public let scale: Double
        public let time: TimeInterval
    }

    private let lock = NSLock()
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
    private var scale = 1.0
    private var observers: [UUID: @Sendable (TimeInterval) -> Void] = [:]
    private var timer: DispatchSourceTimer?

    public init() {}
    deinit { timer?.cancel() }

    public func reset() {
        change {
            point = nil
            clicks = []
            press = nil
            humanKeys = KeyPressDisplay(); agentKeys = KeyPressDisplay()
            humanButtons = []; agentButtons = []
        }
    }

    public func configure(showPointerInRecordings: Bool, showKeyPresses: Bool, showAgentPointer: Bool, scale: Double) {
        change {
            showPointer = showPointerInRecordings
            showKeys = showKeyPresses
            showAgent = showAgentPointer
            self.scale = max(1, scale)
            if !showKeys { press = nil }
        }
    }

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
                if !buttons.subtracting(previous).isEmpty {
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
            let age = time - keyTime
            let text = showKeys && age < 1.5 ? press.map { $0.text + (repeats > 1 ? " ×\(repeats)" : "") } : nil
            return Snapshot(point: point, owner: owner, cursor: cursor, hotspot: hotspot,
                clicks: clicks.filter { time - $0.time < 0.5 }, keyText: text,
                keyOpacity: min(1, max(0, (1.5 - age) / 0.25)),
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
            body()
            tick()
            if timer == nil, !clicks.isEmpty || (showKeys && press != nil) {
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

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        clicks.removeAll { now - $0.time >= 0.5 }
        if now - keyTime >= 1.5 { press = nil }
        for observer in observers.values { observer(now) }
        if clicks.isEmpty && press == nil { timer?.cancel(); timer = nil }
    }
}
