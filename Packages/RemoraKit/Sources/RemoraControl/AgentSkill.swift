import Foundation

/// The agent guide bundled at `Remora.app/Contents/Resources/skills/remora`. An agent loads it through a `remora`
/// link in its user skills folder. Only a link to this copy's folder counts as installed, so Remora never replaces
/// or removes a `remora` skill that another copy or another tool put there.
public struct AgentSkill: Sendable {
    /// Most agents read the shared Agent Skills folder. Claude Code reads only its own.
    public enum Folder: String, CaseIterable, Sendable {
        case agents, claudeCode

        public var name: String { self == .agents ? "Agent Skills standard" : "Claude Code" }
        public var url: URL {
            FileManager.default.homeDirectoryForCurrentUser.appending(path: self == .agents ? ".agents/skills" : ".claude/skills")
        }
    }

    public let folder: URL

    public init(app: URL) { folder = app.appending(path: "Contents/Resources/skills/remora") }

    /// The `remora` link inside a skills folder.
    public func link(in skills: URL) -> CommandLineTool {
        CommandLineTool(target: folder, link: skills.appending(path: "remora"), adoptsOtherCopies: false)
    }

    public func link(in folder: Folder) -> CommandLineTool { link(in: folder.url) }
}
