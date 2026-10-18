import Foundation
import RemoraCore
import Testing

@Test func editorPatchPreservesConcurrentChanges() throws {
    let original = Connection(name: "Original", host: "192.0.2.1", username: "old")
    var edited = original
    edited.name = "Edited"
    edited.domain = ""
    var current = original
    current.host = "192.0.2.2"
    current.username = "new"
    current.lastConnected = Date(timeIntervalSince1970: 123)
    let merged = try ConnectionPatch(from: original, to: edited).applying(to: current)
    #expect(merged.name == "Edited")
    #expect(merged.host == "192.0.2.2")
    #expect(merged.username == "new")
    #expect(merged.domain == nil)
    #expect(merged.lastConnected == current.lastConnected)
}
