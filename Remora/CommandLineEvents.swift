import Foundation
import RemoraControl

extension CommandLineController {
    struct EventSubscriber {
        let session: UUID?
        let continuation: AsyncThrowingStream<ControlEvent, any Error>.Continuation
    }

    func subscribeEvents(_ request: ControlRequest) throws -> ControlReply {
        try request.validateArguments([], sessionAllowed: true)
        let filter = try request.session.map { try resolveSession($0).attemptID }
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<ControlEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.eventSubscribers[id] = nil }
        }
        // Registration and snapshot run on the main actor without suspension.
        eventSubscribers[id] = EventSubscriber(session: filter, continuation: continuation)
        let selected = sessions.tabs.compactMap { sessions.session(for: $0.id) }.filter { filter == nil || $0.attemptID == filter }
        continuation.yield(
            ControlEvent(
                type: "events.snapshot", cursor: nextEventCursor(),
                data: .object([
                    "sessions": .array(selected.map(sessionInfo)), "prompts": .array(selected.compactMap(promptInfo)),
                    "recordings": .array(selected.map(recordingInfo)),
                ])))
        return ControlReply(.success(.object([:])), events: stream)
    }

    func publishEvent(_ type: String, session: SessionViewController, data: ControlValue?) {
        guard !eventSubscribers.isEmpty else { return }
        let value = data ?? (type == "prompt.opened" ? promptInfo(session) : type == "recording.state" ? recordingInfo(session) : sessionInfo(session)) ?? .null
        let event = ControlEvent(type: type, cursor: nextEventCursor(), data: value)
        let previous: UUID?
        if case .object(let fields) = value, case .string(let id) = fields["previousSession"] { previous = UUID(uuidString: id) } else { previous = nil }
        for (id, subscriber) in eventSubscribers {
            guard subscriber.session == nil || subscriber.session == session.attemptID || subscriber.session == previous else { continue }
            if case .dropped = subscriber.continuation.yield(event) {
                subscriber.continuation.finish(
                    throwing: ControlFailure(.streamOverflow, "The event reader fell behind."))
                eventSubscribers[id] = nil
            } else if subscriber.session != nil
                && (type == "session.replaced" || value == .object(["session": .string(session.attemptID.uuidString), "state": .string("closed")]))
            {
                subscriber.continuation.finish()
                eventSubscribers[id] = nil
            }
        }
    }

    private func nextEventCursor() -> String {
        eventSequence += 1
        return "\(eventInstance.uuidString):\(eventSequence)"
    }
}
