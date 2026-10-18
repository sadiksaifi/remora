import Foundation

/// The agent guide bundled at `Remora.app/Contents/Resources/skills/remora`. An agent loads it through a `remora`
/// link in its user skills folder. Only a link to this copy's folder counts as installed, so Remora never replaces
/// or removes a `remora` skill that another copy or another tool put there.
public struct AgentSkill: Sendable {
    public enum Agent: String, CaseIterable, Sendable {
        case claude, codex, opencode, pi

        /// The display name, user skills folder, and the folder whose presence shows the agent is set up, from home.
        private var entry: (name: String, skills: String, detection: String) {
            switch self {
            case .claude: ("Claude Code", ".claude/skills", ".claude")
            case .codex: ("Codex", ".agents/skills", ".codex")
            case .opencode: ("OpenCode", ".config/opencode/skills", ".config/opencode")
            case .pi: ("pi", ".pi/agent/skills", ".pi")
            }
        }

        public var name: String { entry.name }
        public var skills: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: entry.skills) }
        public var isDetected: Bool {
            FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appending(path: entry.detection).path)
        }
    }

    public let folder: URL

    public init(app: URL) { folder = app.appending(path: "Contents/Resources/skills/remora") }

    /// The `remora` link inside a skills folder.
    public func link(in skills: URL) -> CommandLineTool {
        CommandLineTool(target: folder, link: skills.appending(path: "remora"), adoptsOtherCopies: false)
    }

    public func link(for agent: Agent) -> CommandLineTool { link(in: agent.skills) }
}
