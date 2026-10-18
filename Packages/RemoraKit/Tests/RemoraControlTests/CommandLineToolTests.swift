import Foundation
import Testing
@testable import RemoraControl

@Test func installRepairsAndUninstallsOnlyItsOwnLink() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = root.appending(path: "Remora.app/Contents/Helpers/remora")
    try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: helper)
    let tool = CommandLineTool(helper: helper, link: root.appending(path: "bin/remora"))

    #expect(tool.state == .notInstalled)
    try tool.install()
    #expect(tool.state == .installed)

    let moved = CommandLineTool(helper: root.appending(path: "Moved.app/Contents/Helpers/remora"), link: tool.link)
    try FileManager.default.removeItem(at: helper)
    #expect(tool.state == .broken)
    try FileManager.default.createDirectory(at: moved.helper.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: moved.helper)
    try moved.repair()
    #expect(moved.state == .installed)
    try moved.uninstall()
    #expect(moved.state == .notInstalled)

    try Data("someone else's".utf8).write(to: tool.link)
    #expect(tool.state == .conflict)
    #expect(throws: CommandLineTool.Failure.self) { try tool.install() }
    #expect(throws: CommandLineTool.Failure.self) { try tool.uninstall() }
    #expect(try String(contentsOf: tool.link, encoding: .utf8) == "someone else's")
}

@Test(arguments: ["foreign-tool", "Other.app/Contents/Helpers/remora"])
func foreignLinksAreNeverReplacedOrRemoved(destination: String) throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appending(path: UUID().uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let target = root.appending(path: destination)
    let tool = CommandLineTool(helper: root.appending(path: "Remora.app/Contents/Helpers/remora"),
                               link: root.appending(path: "remora"))
    try manager.createSymbolicLink(at: tool.link, withDestinationURL: target)

    // Both a dangling foreign link and a link to an existing foreign helper are conflicts.
    for exists in [false, true] {
        if exists {
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("foreign".utf8).write(to: target)
        }
        #expect(tool.state == .conflict)
        #expect(throws: CommandLineTool.Failure.self) { try tool.install() }
        #expect(throws: CommandLineTool.Failure.self) { try tool.repair() }
        #expect(throws: CommandLineTool.Failure.self) { try tool.uninstall() }
        #expect(try manager.destinationOfSymbolicLink(atPath: tool.link.path) == target.path)
        if exists { #expect(try String(contentsOf: target, encoding: .utf8) == "foreign") }
    }
}
