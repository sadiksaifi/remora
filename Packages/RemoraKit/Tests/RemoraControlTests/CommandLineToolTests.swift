import Foundation
import Testing

@testable import RemoraControl

@Test func installRepairsAndUninstallsOnlyItsOwnLink() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = root.appending(path: "Remora.app/Contents/Helpers/remora")
    try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: helper)
    let tool = CommandLineTool(target: helper, link: root.appending(path: "bin/remora"))

    #expect(tool.state == .notInstalled)
    try tool.install()
    #expect(tool.state == .installed)

    let moved = CommandLineTool(target: root.appending(path: "Moved.app/Contents/Helpers/remora"), link: tool.link)
    try FileManager.default.removeItem(at: helper)
    #expect(tool.state == .broken)
    try FileManager.default.createDirectory(at: moved.target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: moved.target)
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
    let tool = CommandLineTool(
        target: root.appending(path: "Remora.app/Contents/Helpers/remora"),
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

@Test func skillLinkBelongsOnlyToItsOwnCopyOfRemora() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? manager.removeItem(at: root) }
    let skill = AgentSkill(app: root.appending(path: "Remora.app"))
    try manager.createDirectory(at: skill.folder, withIntermediateDirectories: true)
    let link = skill.link(in: root.appending(path: "skills"))

    try link.install()
    #expect(link.state == .installed)
    let other = AgentSkill(app: root.appending(path: "Other/Remora.app")).link(in: root.appending(path: "skills"))
    #expect(other.state == .conflict)
    #expect(throws: CommandLineTool.Failure.self) { try other.uninstall() }
    #expect(link.state == .installed)
    try link.uninstall()
    #expect(link.state == .notInstalled)
}

@Test func skillLinksAreSharedAcrossAppBundleAliases() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? manager.removeItem(at: root) }
    let app = root.appending(path: "Remora.app")
    let skill = AgentSkill(app: app)
    try manager.createDirectory(at: skill.folder, withIntermediateDirectories: true)
    let alias = root.appending(path: "Remora alias.app")
    try manager.createSymbolicLink(at: alias, withDestinationURL: app)
    let skills = root.appending(path: "skills")
    let cliLink = skill.link(in: skills)
    try cliLink.install()

    let settingsLink = AgentSkill(app: alias).link(in: skills)
    #expect(settingsLink.state == .installed)
    try settingsLink.uninstall()
    #expect(cliLink.state == .notInstalled)
}

@Test func shellAnswerIgnoresOutputAroundTheMarkers() {
    // A zsh config with starship prints a cursor escape on the same line as the answer.
    #expect(CommandLineTool.shellAnswer(in: "\u{1B}[5 q\u{1E}/Users/me/.local/bin/remora\u{1E}") == "/Users/me/.local/bin/remora")
    #expect(CommandLineTool.shellAnswer(in: "welcome\n\u{1E}\u{1E}\u{1B}]7;file://mac\u{07}") == "")
    #expect(CommandLineTool.shellAnswer(in: "printf: command not found\n") == nil)
}
