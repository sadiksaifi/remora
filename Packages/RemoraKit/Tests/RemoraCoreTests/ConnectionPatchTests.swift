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

@Test func protocolChangeUsesItsDefaultPortAndPreservesExplicitPort() throws {
    let rdp = Connection(name: "Desktop", host: "host", username: "user")
    let vnc = try ConnectionPatch(kind: .vnc).applying(to: rdp)
    #expect(vnc.port == 5900)
    #expect(vnc.displayAddress == "host")
    #expect(try ConnectionPatch(kind: .rdp).applying(to: vnc).port == 3389)
    let custom = try ConnectionPatch(port: 5907, kind: .vnc).applying(to: rdp)
    #expect(custom.displayAddress == "host:5907")
    #expect(try ConnectionPatch(kind: .rdp).applying(to: custom).port == 5907)
}

@Test func legacyRDPAndVNCConnectionsRoundTrip() throws {
    let legacy = Data(
        """
        {"id":"00000000-0000-0000-0000-000000000001","name":"Old","host":"host","port":3389,"username":"user","kind":"rdp"}
        """.utf8)
    let old = try JSONDecoder().decode(Connection.self, from: legacy)
    #expect(old.kind == .rdp)
    #expect(old.resolution == .fitToWindow)
    #expect(old.vncMode == .standard)
    let vnc = Connection(name: "VNC", host: "host", username: "", kind: .vnc)
    let apple = Connection(name: "Mac", host: "mac", username: "", kind: .vnc, vncMode: .apple)
    let encoded = try JSONEncoder().encode([old, vnc, apple])
    #expect(try JSONDecoder().decode([Connection].self, from: encoded) == [old, vnc, apple])
    #expect(vnc.port == 5900)
}

@Test func savedAppleModeSurvivesDecodeAndEncode() throws {
    let saved = Data(
        """
        {"id":"00000000-0000-0000-0000-000000000002","name":"Mac","host":"mac","port":5900,"username":"","kind":"vnc","vncMode":"apple"}
        """.utf8)
    let encoded = try JSONEncoder().encode(try JSONDecoder().decode(Connection.self, from: saved))
    let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(fields["vncMode"] as? String == "apple")
}

@Test func appleModeAppliesOnlyToVNC() throws {
    let vnc = Connection(name: "Mac", host: "mac", username: "", kind: .vnc)
    let apple = try ConnectionPatch(vncMode: .apple).applying(to: vnc)
    #expect(apple.vncMode == .apple)
    #expect(try ConnectionPatch(name: "Renamed").applying(to: apple).vncMode == .apple)
    #expect(try ConnectionPatch(kind: .rdp).applying(to: apple).vncMode == .standard)
    let rdp = Connection(name: "Desktop", host: "host", username: "user")
    #expect(throws: ConnectionPatch.ValidationFailure.self) { try ConnectionPatch(vncMode: .apple).applying(to: rdp) }
}

@Test func vncPatchesDiscardRDPDomainsWithoutChangingRDP() throws {
    let rdp = Connection(name: "Desktop", host: "host", username: "user", domain: "OFFICE")
    let vnc = try ConnectionPatch(kind: .vnc).applying(to: rdp)
    #expect(vnc.domain == nil)
    #expect(try ConnectionPatch(domain: "IGNORED").applying(to: vnc).domain == nil)
    #expect(try ConnectionPatch(name: "Renamed").applying(to: rdp).domain == "OFFICE")
}
