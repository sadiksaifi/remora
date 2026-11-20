import Foundation
import Testing

@testable import RemoraControl

/// Creates an app with `bundleIdentifier` and an empty file at `inside`, and returns that file.
private func file(in app: URL, at inside: String, bundleIdentifier: String? = nil) throws -> URL {
    let manager = FileManager.default
    let contents = app.appending(path: "Contents")
    try manager.createDirectory(at: contents, withIntermediateDirectories: true)
    if let bundleIdentifier {
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleIdentifier], format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
    }
    let file = app.appending(path: inside)
    try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: file)
    return file
}

private func temporaryFolder() -> URL { FileManager.default.temporaryDirectory.appending(path: UUID().uuidString) }

@Test func installUpdatesAndUninstallsOnlyItsOwnLink() throws {
    let root = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = try file(in: root.appending(path: "Remora.app"), at: "Contents/Helpers/remora")
    let tool = CommandLineTool(target: helper, link: root.appending(path: "bin/remora"))

    #expect(tool.state == .notInstalled)
    try tool.install()
    #expect(tool.state == .installed)

    let moved = CommandLineTool(target: root.appending(path: "Moved.app/Contents/Helpers/remora"), link: tool.link)
    try FileManager.default.removeItem(at: root.appending(path: "Remora.app"))
    #expect(tool.state == .broken)
    _ = try file(in: root.appending(path: "Moved.app"), at: "Contents/Helpers/remora")
    #expect(moved.state == .broken)
    try moved.install()
    #expect(moved.state == .installed)
    try moved.uninstall()
    #expect(moved.state == .notInstalled)

    try Data("someone else's".utf8).write(to: tool.link)
    #expect(tool.state == .conflict)
    #expect(throws: CommandLineTool.Failure.self) { try tool.install(replacingOtherLink: true) }
    #expect(throws: CommandLineTool.Failure.self) { try tool.uninstall() }
    #expect(try String(contentsOf: tool.link, encoding: .utf8) == "someone else's")
}

/// Another tool's link is replaced only when the caller confirms, and the file it points to stays.
@Test func otherLinksAreReplacedOnlyWhenConfirmed() throws {
    let manager = FileManager.default
    let root = temporaryFolder()
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let foreign = root.appending(path: "foreign-tool")
    let tool = CommandLineTool(target: try file(in: root.appending(path: "Remora.app"), at: "Contents/Helpers/remora"), link: root.appending(path: "remora"))
    try manager.createSymbolicLink(at: tool.link, withDestinationURL: foreign)

    // Both a dangling foreign link and a link to an existing foreign file are other links.
    for exists in [false, true] {
        if exists { try Data("foreign".utf8).write(to: foreign) }
        #expect(tool.state == .otherLink)
        #expect(throws: CommandLineTool.Failure.self) { try tool.install() }
        #expect(throws: CommandLineTool.Failure.self) { try tool.uninstall() }
        #expect(tool.destination == CommandLineTool.resolved(foreign.path))
    }
    try tool.install(replacingOtherLink: true)
    #expect(tool.state == .installed)
    #expect(try String(contentsOf: foreign, encoding: .utf8) == "foreign")
}

/// A helper in another app counts as Remora's only with Remora's bundle identifier. A dangling link to a helper counts, so a renamed copy can repair it.
@Test func helperLinksAreOwnedByBundleIdentifier() throws {
    let manager = FileManager.default
    let root = temporaryFolder()
    defer { try? manager.removeItem(at: root) }
    let helper = "Contents/Helpers/remora"
    let tool = CommandLineTool(
        target: try file(in: root.appending(path: "Remora.app"), at: helper, bundleIdentifier: "com.peblon.remora"), link: root.appending(path: "remora"))

    let variant = try file(in: root.appending(path: "Remora Dev.app"), at: helper, bundleIdentifier: "com.peblon.remora.dev")
    try manager.createSymbolicLink(at: tool.link, withDestinationURL: variant)
    #expect(tool.state == .otherLink)
    // Without its helper, the variant's app still owns the link.
    try manager.removeItem(at: variant)
    #expect(tool.state == .otherLink)
    #expect(throws: CommandLineTool.Failure.self) { try tool.install() }
    #expect(try manager.destinationOfSymbolicLink(atPath: tool.link.path) == variant.path)

    try manager.removeItem(at: tool.link)
    let copy = root.appending(path: "Remora copy.app")
    try manager.createSymbolicLink(at: tool.link, withDestinationURL: try file(in: copy, at: helper, bundleIdentifier: "com.peblon.remora"))
    #expect(tool.state == .otherCopy)
    #expect(tool.linkedApp == CommandLineTool.resolved(copy.path))
    try manager.removeItem(at: copy.appending(path: helper))
    #expect(tool.state == .broken)
    try tool.install()
    #expect(tool.state == .installed)

    try manager.removeItem(at: tool.link)
    try manager.createSymbolicLink(at: tool.link, withDestinationURL: root.appending(path: "Renamed.app/Contents/Helpers/remora"))
    #expect(tool.state == .broken)
    try tool.install()
    #expect(try manager.destinationOfSymbolicLink(atPath: tool.link.path) == tool.target.path)
}

/// Links resolve as the file system resolves them, even when the link's folder is itself a link.
@Test func linksResolveThroughLinkedFolders() throws {
    let manager = FileManager.default
    let root = temporaryFolder()
    defer { try? manager.removeItem(at: root) }
    let helper = "Contents/Helpers/remora"
    let real = root.appending(path: "deep/bin")
    try manager.createDirectory(at: real, withIntermediateDirectories: true)
    try manager.createSymbolicLink(at: root.appending(path: "bin"), withDestinationURL: real)
    let app = root.appending(path: "deep/Remora.app")
    let tool = CommandLineTool(target: try file(in: app, at: helper, bundleIdentifier: "com.peblon.remora"), link: root.appending(path: "bin/remora"))

    // ../Foreign.app is deep/Foreign.app, next to the real folder, not next to the bin link.
    let foreign = try file(in: root.appending(path: "deep/Foreign.app"), at: helper, bundleIdentifier: "com.example.foreign")
    try manager.createSymbolicLink(atPath: tool.link.path, withDestinationPath: "../Foreign.app/\(helper)")
    #expect(tool.state == .otherLink)
    #expect(throws: CommandLineTool.Failure.self) { try tool.install() }
    try manager.removeItem(at: foreign)
    #expect(tool.state == .otherLink)

    // `..` after a linked folder leaves the folder the link points to, so the foreign app still owns this dangling link.
    try manager.removeItem(at: tool.link)
    try manager.createSymbolicLink(at: root.appending(path: "deep/bin/alias"), withDestinationURL: root.appending(path: "deep/bin/nested/inner"))
    try manager.createDirectory(at: root.appending(path: "deep/bin/nested/inner"), withIntermediateDirectories: true)
    _ = try file(in: root.appending(path: "deep/bin/nested/Foreign.app"), at: helper, bundleIdentifier: "com.example.foreign")
    try manager.removeItem(at: root.appending(path: "deep/bin/nested/Foreign.app/\(helper)"))
    try manager.createSymbolicLink(atPath: tool.link.path, withDestinationPath: "alias/../Foreign.app/\(helper)")
    #expect(tool.state == .otherLink)
    #expect(throws: CommandLineTool.Failure.self) { try tool.install() }

    // A link through an alias of this app is this copy's.
    try manager.removeItem(at: tool.link)
    let alias = root.appending(path: "Alias.app")
    try manager.createSymbolicLink(at: alias, withDestinationURL: app)
    try manager.createSymbolicLink(at: tool.link, withDestinationURL: alias.appending(path: helper))
    #expect(tool.state == .installed)
}

@Test func skillLinkToAnotherCopyCanBeUpdated() throws {
    let manager = FileManager.default
    let root = temporaryFolder()
    defer { try? manager.removeItem(at: root) }
    let skills = root.appending(path: "skills")
    let inside = "Contents/Resources/skills/remora"
    for app in ["Remora.app", "Other/Remora.app"] { _ = try file(in: root.appending(path: app), at: inside, bundleIdentifier: "com.peblon.remora") }
    _ = try file(in: root.appending(path: "Tool.app"), at: inside, bundleIdentifier: "com.example.tool")
    let link = AgentSkill(app: root.appending(path: "Remora.app"), name: "remora").link(in: skills)
    let other = AgentSkill(app: root.appending(path: "Other/Remora.app"), name: "remora").link(in: skills)
    let tool = AgentSkill(app: root.appending(path: "Tool.app"), name: "remora").link(in: skills)

    try link.install()
    #expect(link.state == .installed)
    #expect(other.state == .otherCopy)
    try other.install()
    #expect(other.state == .installed)
    #expect(link.state == .otherCopy)

    try tool.install(replacingOtherLink: true)
    #expect(link.state == .otherLink)
    #expect(throws: CommandLineTool.Failure.self) { try link.uninstall() }
    #expect(tool.state == .installed)
    try tool.uninstall()
    #expect(link.state == .notInstalled)
}

@Test func skillLinksAreSharedAcrossAppBundleAliases() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? manager.removeItem(at: root) }
    let app = root.appending(path: "Remora.app")
    let skill = AgentSkill(app: app, name: "remora")
    try manager.createDirectory(at: skill.folder, withIntermediateDirectories: true)
    let alias = root.appending(path: "Remora alias.app")
    try manager.createSymbolicLink(at: alias, withDestinationURL: app)
    let skills = root.appending(path: "skills")
    let cliLink = skill.link(in: skills)
    try cliLink.install()

    let settingsLink = AgentSkill(app: alias, name: "remora").link(in: skills)
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
