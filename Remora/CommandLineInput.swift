import Foundation
import RDPSession
import RemoraControl
import RemoraCore

extension CommandLineController {
    func handleInput(_ request: ControlRequest) async throws -> ControlValue {
        let session = try resolveSession(request.session)
        let id = session.attemptID
        guard session.pendingPrompt == nil else { throw ControlFailure(.promptRequired, "The session requires a prompt response.") }
        guard session.isConnected, let backend = session.inputBackend, let size = session.desktopSize else {
            throw ControlFailure(.notConnected, "The session is not connected.")
        }
        let capabilities = backend.inputCapabilities
        if request.command == "capabilities" {
            try request.validateArguments([], sessionAllowed: true)
            return .object(["session": .string(id.uuidString), "keys": .array(PhysicalKey.names.map(ControlValue.string)),
                "unicode": .bool(capabilities.contains(.unicode)), "extendedButtons": .bool(capabilities.contains(.extendedButtons)),
                "horizontalWheel": .bool(capabilities.contains(.horizontalWheel)), "maximumActions": .number(256), "maximumDurationMs": .number(60_000)])
        }
        try session.checkAgentInput()
        guard session.activeAgentInput == nil else { throw ControlFailure(.inputBusy, "Another input command is running on this session.") }
        let receipt: ScreenshotReceipt?
        if let image = try request.string("image") {
            guard let uuid = UUID(uuidString: image), let found = screenshotReceipts.first(where: { $0.id == uuid }),
                  found.session == id, found.geometry.desktop == size, found.geometryRevision == session.inputGeometryRevision else {
                throw ControlFailure(.imageExpired, "The screenshot mapping expired. Take a new screenshot.")
            }
            receipt = found
        } else { receipt = nil }
        let geometryRevision = session.inputGeometryRevision
        let plan = try InputPlan(request, size: size, geometry: receipt?.geometry, capabilities: capabilities)
        try session.attachAgentControl(agent: request.agent)
        guard let input = backend.beginAgentInput() else { throw ControlFailure(.notConnected, "The session is not connected.") }
        session.activeAgentInput = input
        session.agentInputCancellation = nil
        var finished = false
        defer { session.activeAgentInput = nil; session.agentInputCancellation = nil }
        let deadline = ContinuousClock.now.advanced(by: .seconds(min(60, request.timeout ?? 10)))
        var completed = 0
        var submitted = 0
        func check() throws {
            if let failure = session.agentInputCancellation { throw failure }
            guard !Task.isCancelled else { throw ControlFailure(.cancelled, "The command was interrupted.") }
            guard session.attemptID == id, sessions.session(for: session.connection.id) === session else {
                throw ControlFailure(.sessionEnded, "The session attempt was closed or replaced.")
            }
            guard session.isConnected else { throw ControlFailure(.notConnected, "The session disconnected during input.") }
            guard session.inputGeometryRevision == geometryRevision else {
                throw ControlFailure(.imageExpired, "The desktop geometry changed during input. Take a new screenshot.")
            }
            guard ContinuousClock.now < deadline else { throw ControlFailure(.timeout, "The input command timed out.") }
        }
        do {
            for step in plan.steps {
                try check()
                switch step {
                case .event(let event):
                    try await input.send(event, deadline: deadline)
                    submitted += 1
                    if case .pointer(let point, let buttons) = event { session.showAgentPointer(at: point, buttons: buttons) }
                case .delay(let milliseconds):
                    let until = min(deadline, ContinuousClock.now.advanced(by: .milliseconds(milliseconds)))
                    // Poll cancellation from Take Over while held in a delay.
                    while ContinuousClock.now < until {
                        try check()
                        try await Task.sleep(until: min(until, ContinuousClock.now.advanced(by: .milliseconds(10))), clock: .continuous)
                    }
                case .completed: completed += 1
                }
            }
            try check()
            finished = true
            guard await input.finish() else { throw ControlFailure(.backendFailed, "The RDP input release failed. The transport was closed.") }
            try check()
            return .object(["session": .string(id.uuidString), "submittedActions": .number(Double(completed)),
                "submittedEvents": .number(Double(submitted)), "acknowledgment": .string("protocol-submission")])
        } catch {
            if !finished {
                input.cancel()
                await input.finish()
            }
            let failure: ControlFailure
            if let cancelled = session.agentInputCancellation { failure = cancelled }
            else if let known = error as? ControlFailure { failure = known }
            else if Task.isCancelled || error is CancellationError { failure = ControlFailure(.cancelled, "The command was interrupted.") }
            else if let backendFailure = error as? AgentInputFailure {
                switch backendFailure {
                case .timedOut: failure = ControlFailure(.timeout, "The input command timed out.")
                case .sessionEnded: failure = ControlFailure(.sessionEnded, "The session ended during input.")
                case .cancelled: failure = ControlFailure(.cancelled, "The input request was cancelled.")
                case .submissionFailed: failure = ControlFailure(.backendFailed, "The RDP input submission failed.")
                }
            } else { failure = ControlFailure(.backendFailed, "The RDP input submission failed.") }
            throw ControlFailure(failure.code, failure.message, hint: failure.hint,
                details: .object(["submittedActions": .number(Double(completed)), "submittedEvents": .number(Double(submitted))]))
        }
    }
}

/// Validates the entire request, including held-state conflicts and negotiated
/// capabilities, before admission. Only send() adds work to the C queue.
private struct InputPlan {
    enum Step {
        case event(AgentInputEvent), delay(Double), completed
    }
    var steps: [Step] = []
    private var keys: Set<PhysicalKey> = []
    private var buttons: PointerButtons = []
    private var duration = 0.0
    private let size: DesktopSize
    private let geometry: ScreenshotGeometry?
    private let capabilities: AgentInputCapabilities

    init(_ request: ControlRequest, size: DesktopSize, geometry: ScreenshotGeometry?, capabilities: AgentInputCapabilities) throws {
        self.size = size; self.geometry = geometry; self.capabilities = capabilities
        let actions: [ControlValue]
        if request.command == "input" {
            try request.validateArguments(["image", "actions"], sessionAllowed: true)
            guard case .array(let array) = request.arguments["actions"], array.count <= 256 else {
                throw ControlFailure(.invalidArgument, "Input requires a JSON array of up to 256 actions.")
            }
            actions = array
        } else {
            var fields = request.arguments
            fields.removeValue(forKey: "image")
            fields["action"] = .string(request.command)
            actions = [.object(fields)]
        }
        for action in actions {
            guard case .object(let fields) = action, case .string(let name) = fields["action"] else {
                throw ControlFailure(.invalidArgument, "Each batch action needs an action name.")
            }
            var arguments = fields
            arguments.removeValue(forKey: "action")
            try append(ControlRequest(command: name, arguments: arguments))
            steps.append(.completed)
            guard duration <= 60_000 else {
                throw ControlFailure(.invalidArgument, "Input exceeds 60 seconds of intended duration.")
            }
        }
        if request.arguments["image"] != nil, ["type", "key"].contains(request.command) {
            throw ControlFailure(.invalidArgument, "This command does not accept image.")
        }
    }

    private mutating func event(_ event: AgentInputEvent) {
        steps.append(.event(event))
    }
    private mutating func delay(_ ms: Double) { steps.append(.delay(ms)); duration += ms }

    private func number(_ request: ControlRequest, _ field: String, default fallback: Double? = nil) throws -> Double {
        if request.arguments[field] == nil, let fallback { return fallback }
        guard case .number(let value) = request.arguments[field], value.isFinite else {
            throw ControlFailure(.invalidArgument, "\(field) requires a finite number.")
        }
        return value
    }

    private func integer(_ request: ControlRequest, _ field: String, range: ClosedRange<Int>, default fallback: Int? = nil) throws -> Int {
        let n = try number(request, field, default: fallback.map(Double.init))
        guard n.rounded() == n, n >= Double(range.lowerBound), n <= Double(range.upperBound) else {
            throw ControlFailure(.invalidArgument, "\(field) must be an integer from \(range.lowerBound) to \(range.upperBound).")
        }
        return Int(n)
    }

    private func point(_ request: ControlRequest, _ field: String? = nil) throws -> RemotePoint {
        let x: Double, y: Double
        if let field {
            guard case .array(let pair) = request.arguments[field], pair.count == 2,
                  case .number(let a) = pair[0], case .number(let b) = pair[1] else {
                throw ControlFailure(.invalidArgument, "\(field) requires [x,y].")
            }
            x = a; y = b
        } else { x = try number(request, "x"); y = try number(request, "y") }
        let bounds = geometry?.encoded ?? size
        guard x.isFinite, y.isFinite, x.rounded() == x, y.rounded() == y,
              x >= 0, y >= 0, x < Double(bounds.width), y < Double(bounds.height) else {
            throw ControlFailure(.invalidArgument, "Coordinates must be integer pixels inside the image or remote desktop.")
        }
        let mapped = try geometry?.remotePoint(x: Int(x), y: Int(y)) ?? (x: Int(x), y: Int(y))
        guard let rx = UInt16(exactly: mapped.x), let ry = UInt16(exactly: mapped.y) else {
            throw ControlFailure(.invalidArgument, "Coordinates exceed the RDP pointer range.")
        }
        return RemotePoint(x: rx, y: ry)
    }

    private func button(_ request: ControlRequest) throws -> PointerButtons {
        let name = try request.string("button") ?? "left"
        let value: PointerButtons
        switch name {
        case "left": value = .left
        case "right": value = .right
        case "middle": value = .middle
        case "back": value = .back
        case "forward": value = .forward
        default: throw ControlFailure(.invalidArgument, "button must be left, right, middle, back or forward.")
        }
        if !value.intersection([.back, .forward]).isEmpty, !capabilities.contains(.extendedButtons) {
            throw ControlFailure(.unsupported, "The server did not negotiate extended mouse buttons.")
        }
        return value
    }

    private func chord(_ text: String, modifiersOnly: Bool = false) throws -> [PhysicalKey] {
        do { return try PhysicalKey.chord(text, modifiersOnly: modifiersOnly) }
        catch { throw ControlFailure(.invalidArgument, error.localizedDescription) }
    }

    private mutating func modifiers(_ request: ControlRequest) throws -> [PhysicalKey] {
        let requested = try request.string("modifiers").map { try chord($0, modifiersOnly: true) } ?? []
        let additions = requested.filter { !keys.contains($0) }
        for key in additions { event(.key(key, down: true)) }
        return additions
    }

    private mutating func release(_ additions: [PhysicalKey]) {
        for key in additions.reversed() { event(.key(key, down: false)) }
    }

    private mutating func append(_ request: ControlRequest) throws {
        switch request.command {
        case "move":
            try request.validateArguments(["x", "y"])
            event(.pointer(try point(request), buttons))
        case "click", "drag":
            let drag = request.command == "drag"
            try request.validateArguments(drag ? ["from", "to", "button", "modifiers", "durationMs"] : ["x", "y", "button", "count", "modifiers"])
            let start = try point(request, drag ? "from" : nil)
            let end = drag ? try point(request, "to") : start
            let button = try button(request)
            guard buttons.intersection(button).isEmpty else { throw ControlFailure(.invalidArgument, "Release the held button before clicking or dragging with it.") }
            let count = drag ? 1 : try integer(request, "count", range: 1...3, default: 1)
            let milliseconds = drag ? try number(request, "durationMs", default: 500) : 0
            guard !drag || (1...10_000).contains(milliseconds) else { throw ControlFailure(.invalidArgument, "Drag duration must be 1 to 10000 milliseconds.") }
            let additions = try modifiers(request)
            for index in 0..<count {
                event(.pointer(start, buttons))
                event(.pointer(start, buttons.union(button)))
                if drag {
                    let samples = max(1, Int(ceil(milliseconds / 16)))
                    for sample in 1...samples {
                        delay(milliseconds / Double(samples))
                        let fraction = Double(sample) / Double(samples)
                        let x = Double(start.x) + (Double(end.x) - Double(start.x)) * fraction
                        let y = Double(start.y) + (Double(end.y) - Double(start.y)) * fraction
                        event(.pointer(RemotePoint(x: UInt16(x.rounded()), y: UInt16(y.rounded())), buttons.union(button)))
                    }
                } else { delay(20) }
                event(.pointer(end, buttons))
                if index + 1 < count { delay(80) }
            }
            release(additions)
        case "scroll":
            try request.validateArguments(["at", "dx", "dy"])
            let at = try point(request, "at")
            let dx = try number(request, "dx", default: 0), dy = try number(request, "dy", default: 0)
            if dx != 0, !capabilities.contains(.horizontalWheel) { throw ControlFailure(.unsupported, "The server did not negotiate a horizontal wheel.") }
            let h = (dx * 120).rounded(), v = (-dy * 120).rounded()
            guard h >= Double(Int32.min), h <= Double(Int32.max), v >= Double(Int32.min), v <= Double(Int32.max) else {
                throw ControlFailure(.invalidArgument, "The wheel deltas exceed the RDP range.")
            }
            let horizontal = Int32(h), vertical = Int32(v)
            guard horizontal != 0 || vertical != 0 else { throw ControlFailure(.invalidArgument, "Scroll must move at least 1/120 notch.") }
            event(.pointer(at, buttons))
            event(.wheel(.init(vertical: vertical, horizontal: horizontal)))
        case "type":
            try request.validateArguments(["text"])
            let text = try request.string("text", required: true)!
            // Check before expanding the text into steps.
            let count = text.reduce(0) { $0 + ($1 == "\r\n" ? 1 : $1.unicodeScalars.count) }
            guard duration + Double(count) * 5 <= 60_000 else {
                throw ControlFailure(.invalidArgument, "Input exceeds 60 seconds of intended duration.")
            }
            let enter = try chord("Enter")[0]
            for character in text {
                switch character {
                case "\n", "\r", "\r\n":
                    guard !keys.contains(enter) else { throw ControlFailure(.invalidArgument, "Release the held Enter key before typing line breaks.") }
                    event(.key(enter, down: true))
                    event(.key(enter, down: false))
                    delay(5)
                default:
                    guard capabilities.contains(.unicode) else { throw ControlFailure(.unsupported, "The server did not negotiate Unicode keyboard input.") }
                    for scalar in character.unicodeScalars { event(.unicode(scalar)); delay(5) }
                }
            }
        case "key":
            try request.validateArguments(["key", "repeat"])
            let chord = try chord(request.string("key", required: true)!)
            let count = try integer(request, "repeat", range: 1...100, default: 1)
            guard !keys.contains(chord.last!) else { throw ControlFailure(.invalidArgument, "Release the held terminal key before pressing its chord.") }
            let additions = chord.filter { !keys.contains($0) }
            for index in 0..<count {
                for key in additions {
                    if key.isPause { event(.pause) }
                    else { event(.key(key, down: true)) }
                }
                delay(20)
                release(additions.filter { !$0.isPause })
                if index + 1 < count { delay(20) }
            }
        case "delay":
            try request.validateArguments(["durationMs"])
            let ms = try number(request, "durationMs")
            guard (0...60_000).contains(ms) else { throw ControlFailure(.invalidArgument, "Delay must be 0 to 60000 milliseconds.") }
            delay(ms)
        case "key-down", "key-up":
            try request.validateArguments(["key"])
            let chord = try chord(request.string("key", required: true)!)
            guard chord.count == 1, let key = chord.first, !key.isPause else { throw ControlFailure(.invalidArgument, "Raw key actions need one holdable physical key. Pause is a pulse.") }
            let down = request.command == "key-down"
            guard keys.contains(key) != down else { throw ControlFailure(.invalidArgument, "The key must be pressed and released in order within this batch.") }
            if down { keys.insert(key) } else { keys.remove(key) }
            event(.key(key, down: down))
        case "button-down", "button-up":
            try request.validateArguments(["x", "y", "button"])
            let point = try point(request)
            let button = try button(request)
            let down = request.command == "button-down"
            guard buttons.contains(button) != down else { throw ControlFailure(.invalidArgument, "The button must be pressed and released in order within this batch.") }
            if down { buttons.insert(button) } else { buttons.remove(button) }
            event(.pointer(point, buttons))
        default: throw ControlFailure(.invalidArgument, "Unknown input action '\(request.command)'.")
        }
    }
}
