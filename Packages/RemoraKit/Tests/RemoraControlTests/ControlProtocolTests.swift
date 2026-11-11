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
