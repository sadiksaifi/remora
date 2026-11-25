import Foundation
import Testing

@testable import RemoraControl

@Test func durationUnitsAndBounds() throws {
    #expect(try CommandTimeout("250ms").seconds == 0.25)
    #expect(try CommandTimeout("1.5s").seconds == 1.5)
    #expect(try CommandTimeout("2m").seconds == 120)
    #expect(try CommandTimeout("0").seconds == 0)
    for invalid in ["-1", "nan", "inf", "1h", "", "1e3", "90000s"] {
        #expect(throws: ControlFailure.self) { try CommandTimeout(invalid) }
    }
}

@Test func requestsRejectUnknownOrMalformedFields() throws {
    let decoder = JSONDecoder()
    let request = try decoder.decode(ControlRequest.self, from: Data(#"{"command":"app.show","arguments":{"page":"settings"}}"#.utf8))
    #expect(request.arguments == ["page": .string("settings")])
    #expect(request.agent == nil)
    let encoded = try JSONEncoder().encode(ControlRequest(command: "key", arguments: ["chord": .string("Enter")], agent: "codex"))
    #expect(try decoder.decode(ControlRequest.self, from: encoded).agent == "codex")
    for invalid in [
        #"{"command":"app.quit","extra":true}"#, #"{"command":""}"#, #"{"command":"app.show","arguments":[]}"#, #"{"command":"app.show","session":42}"#,
        #"{"command":"key","agent":7}"#,
    ] {
        #expect(throws: (any Error).self) { try decoder.decode(ControlRequest.self, from: Data(invalid.utf8)) }
    }
}

@Test func failureWithoutItsOwnHintTakesTheCodesHint() {
    #expect(ControlFailure(.notConnected, "The session is not connected.").hint == ControlFailure.Code.notConnected.hint)
    #expect(ControlFailure(.notConnected, "The session is not connected.", hint: "Reconnect.").hint == "Reconnect.")
    // Every code an agent can act on names a next step. An interrupted command has none.
    #expect(ControlFailure.Code.allCases.filter(\.hint.isEmpty) == [.cancelled])
}

@Test func envelopesUseOneResultOrError() throws {
    let response = ControlResponse.failure(ControlFailure(.outcomeUnknown, "Reply lost.", hint: "Inspect app status."))
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
    #expect(object["ok"] as? Bool == false)
    #expect(object["result"] == nil)
    let error = try #require(object["error"] as? [String: String])
    #expect(error == ["code": "outcome-unknown", "message": "Reply lost.", "hint": "Inspect app status."])
    #expect(try JSONDecoder().decode(ControlResponse.self, from: JSONEncoder().encode(response)) == response)
}

@Test func passwordLineEndingIsRemovedExactlyOnce() throws {
    #expect(try PasswordInput.decode(Data(" secret \r\n".utf8)) == " secret ")
    #expect(try PasswordInput.decode(Data("a\n\n".utf8)) == "a\n")
    #expect(throws: ControlFailure.self) { try PasswordInput.decode(Data([0])) }
    #expect(throws: ControlFailure.self) { try PasswordInput.decode(Data([255])) }
}

/// A regular file never reports its end to `FileHandle.readabilityHandler`, so stdin from `< file` or a here-string once hung.
@Test func standardInputReadsAPipeAndARegularFileToTheirEnd() async throws {
    let pipe = Pipe()
    pipe.fileHandleForWriting.write(Data("[]".utf8))
    try pipe.fileHandleForWriting.close()
    #expect(try await StandardInput.read(pipe.fileHandleForReading.fileDescriptor, until: .now + .seconds(60)) == Data("[]".utf8))

    for contents in [Data("[]\n".utf8), Data(), Data(count: 1_048_575)] {
        #expect(try await readToEnd(file(contents)) == contents)
    }
    await #expect(throws: ControlFailure(.invalidArgument, "Stdin exceeds the request size limit.")) {
        try await readToEnd(file(Data(count: 1_048_576)))
    }
}

@Test func standardInputThatNeverEndsFailsAtTheDeadline() async throws {
    let pipe = Pipe()
    let writer = pipe.fileHandleForWriting
    // Closing the writer ends a read that ignores the deadline, so this test fails instead of hanging.
    let watchdog = Task {
        try await Task.sleep(for: .seconds(10))
        try writer.close()
    }
    defer {
        watchdog.cancel()
        try? writer.close()
    }
    let start = ContinuousClock.now
    let failure = await #expect(throws: ControlFailure.self) {
        try await StandardInput.read(pipe.fileHandleForReading.fileDescriptor, until: start + .milliseconds(200))
    }
    #expect(failure?.code == .timeout)
    // The upper bound only catches a read that ignores the deadline; CI runs these tests on few cores.
    let elapsed = start.duration(to: .now)
    #expect(elapsed >= .milliseconds(200) && elapsed < .seconds(10))
}

/// Ready data does not let a read outlive its deadline.
@Test func standardInputPastItsDeadlineReadsNothing() async throws {
    let handle = try file(Data("[]".utf8))
    defer { try? handle.close() }
    let failure = await #expect(throws: ControlFailure.self) { try await StandardInput.read(handle.fileDescriptor, until: .now) }
    #expect(failure?.code == .timeout)
}

/// A program that starts the CLI can hand it a nonblocking pipe, whose read fails with EAGAIN until data arrives.
@Test func nonblockingStandardInputWaitsForData() async throws {
    let pipe = Pipe()
    let input = pipe.fileHandleForReading.fileDescriptor
    #expect(fcntl(input, F_SETFL, fcntl(input, F_GETFL) | O_NONBLOCK) == 0)
    pipe.fileHandleForWriting.write(Data("a".utf8))
    let read = Task { try await StandardInput.read(input, until: .now + .seconds(60)) }
    try await waitUntilDrained(input)
    pipe.fileHandleForWriting.write(Data("b".utf8))
    try pipe.fileHandleForWriting.close()
    #expect(try await read.value == Data("ab".utf8))
}

/// A cancelled read stops reading, so data written after it reaches the next read.
@Test func cancelledStandardInputReadLeavesLaterDataForTheNextRead() async throws {
    let pipe = Pipe()
    let input = pipe.fileHandleForReading.fileDescriptor
    pipe.fileHandleForWriting.write(Data("a".utf8))
    let read = Task { try await StandardInput.read(input, until: .now + .seconds(60)) }
    try await waitUntilDrained(input)
    read.cancel()
    let failure = await #expect(throws: ControlFailure.self) { try await read.value }
    #expect(failure?.code == .cancelled)
    pipe.fileHandleForWriting.write(Data("next".utf8))
    try pipe.fileHandleForWriting.close()
    #expect(try await StandardInput.read(input, until: .now + .seconds(60)) == Data("next".utf8))
}

/// Waits until a reader has taken every byte in the pipe, which shows that the read has started.
private func waitUntilDrained(_ descriptor: Int32) async throws {
    let limit = ContinuousClock.now + .seconds(10)
    var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    while poll(&event, 1, 0) > 0, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(1)) }
}

private func readToEnd(_ handle: FileHandle) async throws -> Data {
    defer { try? handle.close() }
    return try await StandardInput.read(handle.fileDescriptor, until: .now + .seconds(60))
}

private func file(_ contents: Data) throws -> FileHandle {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try contents.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try FileHandle(forReadingFrom: url)
}
