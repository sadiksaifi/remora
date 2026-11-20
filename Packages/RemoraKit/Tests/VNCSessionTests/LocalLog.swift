import Foundation
import OSLog

/// Returns the VNC log messages this process wrote since `start` that `matching` selects, once `done` accepts them.
///
/// OSLogStore shapes the wait. One enumeration takes seconds, more on a loaded machine. An entry written before
/// the call can be absent from one enumeration and present in the next. One enumeration can also return the same
/// entry twice, so each entry counts once by its timestamp and message. A test that passes stops at its first
/// accepted enumeration. The deadline only bounds the wait for an entry that never arrives.
func localVNCLog(
    since start: Date, matching: @escaping @Sendable (String) -> Bool, until done: @escaping @Sendable ([String]) -> Bool
) async throws -> [String] {
    // Enumeration is synchronous. Running it off MainActor keeps the parallel session tests on time.
    try await Task.detached {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "subsystem == %@ AND category == %@", "com.peblon.remora", "VNC")
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var messages: [String] = []
        repeat {
            var seen = Set<String>()
            messages = try store.getEntries(at: store.position(date: start), matching: predicate).compactMap { entry in
                guard let entry = entry as? OSLogEntryLog, matching(entry.composedMessage) else { return nil }
                return seen.insert("\(entry.date.timeIntervalSince1970) \(entry.composedMessage)").inserted ? entry.composedMessage : nil
            }
            if done(messages) { break }
            try await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        return messages
    }.value
}
