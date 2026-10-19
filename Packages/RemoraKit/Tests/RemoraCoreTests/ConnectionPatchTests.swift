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
    let legacy = Data("""
    {"id":"00000000-0000-0000-0000-000000000001","name":"Old","host":"host","port":3389,"username":"user","kind":"rdp"}
    """.utf8)
    let old = try JSONDecoder().decode(Connection.self, from: legacy)
    #expect(old.kind == .rdp)
    #expect(old.resolution == .fitToWindow)
    let vnc = Connection(name: "VNC", host: "host", username: "", kind: .vnc)
    let encoded = try JSONEncoder().encode([old, vnc])
    #expect(try JSONDecoder().decode([Connection].self, from: encoded) == [old, vnc])
    #expect(vnc.port == 5900)
}

@Test func vncPatchesDiscardRDPDomainsWithoutChangingRDP() throws {
    let rdp = Connection(name: "Desktop", host: "host", username: "user", domain: "OFFICE")
    let vnc = try ConnectionPatch(kind: .vnc).applying(to: rdp)
    #expect(vnc.domain == nil)
    #expect(try ConnectionPatch(domain: "IGNORED").applying(to: vnc).domain == nil)
    #expect(try ConnectionPatch(name: "Renamed").applying(to: rdp).domain == "OFFICE")
}
