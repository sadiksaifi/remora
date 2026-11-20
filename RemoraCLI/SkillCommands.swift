import ArgumentParser
import Foundation
import RemoraControl

/// A link to an app on a disk image or in App Translocation's temporary copy would soon break.
let readOnlyDiscussion = "It refuses while \(AppIdentity.current.name) runs from a disk image or a temporary location. Move the app to Applications first."

/// The states of a CLI or skill link, and the command that fixes each one.
func linkStates(fix: String) -> String {
    let name = AppIdentity.current.name
    return """
        A link's state is one of:
        installed: the link points to this copy of \(name).
        notInstalled: nothing is at the path.
        otherCopy: the link points to another copy of \(name). `\(fix)` points it at this copy.
        broken: the link points to a copy of \(name) that was moved or deleted. `\(fix)` points it at this copy.
        otherLink: the link points to another app or tool. `\(fix) --replace` replaces the link. Ask the user first.
        conflict: a file or folder that isn't a link is at the path. \(name) never replaces it.
        """
}

/// Claude Code reads only its own skills folder. The other agents read the shared Agent Skills folder.
enum SkillAgent: String, CaseIterable, ExpressibleByArgument {
    case agents, codex, opencode, pi, muse, antigravity, cursor, fx
    case claudeCode = "claude-code"

    var folder: AgentSkill.Folder { self == .claudeCode ? .claudeCode : .agents }
}

struct SkillCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skill", abstract: "Link the bundled agent skill into AI agents' skills folders.",
        subcommands: [Path.self, Install.self, Uninstall.self])

    static var skill: AgentSkill { AgentSkill() }

    struct Path: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the bundled skill folder.")
        @OptionGroup var options: CommonOptions
        func run() {
            if options.json { Output.write(.success(.object(["path": .string(skill.folder.path)]))) } else { print(skill.folder.path) }
        }
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Link the skill as \(AppIdentity.current.commandName) in ~/.agents/skills and ~/.claude/skills, or point those links at this copy.",
            discussion: linkStates(fix: "\(AppIdentity.current.commandName) skill install") + "\n\n" + readOnlyDiscussion)
        @OptionGroup var targets: Targets
        @Flag(help: "Also replace a link to another app's or tool's skill. A file or folder that isn't a link is never replaced.") var replace = false
        func run() throws { try targets.apply(install: true, replace: replace) }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove the \(AppIdentity.current.commandName) links that point to a copy of this app's skill. Other links stay.")
        @OptionGroup var targets: Targets
        func run() throws { try targets.apply(install: false, replace: false) }
    }

    struct Targets: ParsableArguments {
        @OptionGroup var options: CommonOptions
        @Option(help: "Use only this agent's skills folder.") var agent: SkillAgent?
        @Option(help: "Use this skills folder instead.") var dir: String?

        func validate() throws {
            if agent != nil, dir != nil { throw ValidationError("Choose --agent or --dir.") }
        }

        /// Replaces another app's or tool's link only with `replace`, and never removes one.
        func apply(install: Bool, replace: Bool) throws {
            let links: [(name: String, link: CommandLineTool)]
            if let dir {
                links = [("Folder", skill.link(in: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)))]
            } else {
                links = (agent.map { [$0.folder] } ?? AgentSkill.Folder.allCases).map { ($0.name, skill.link(in: $0)) }
            }
            var results: [ControlValue] = []
            for (name, link) in links {
                do {
                    let othersLink = link.state == .conflict || (link.state == .otherLink && !(install && replace))
                    if !othersLink {
                        if install { try link.install(replacingOtherLink: replace) } else if link.state != .notInstalled { try link.uninstall() }
                    }
                } catch {
                    throw ControlFailure(.ioFailed, error.localizedDescription, hint: (error as? CommandLineTool.Failure)?.recoverySuggestion)
                }
                results.append(.object(["agent": .string(name), "path": .string(link.link.path), "state": .string(link.state.rawValue)]))
                if !options.json {
                    let state =
                        [.otherLink, .conflict].contains(link.state) ? "in use by another skill" : link.state == .notInstalled ? "not installed" : "installed"
                    print("\(name): \(state) at \(link.displayPath)")
                }
            }
            if install {
                let inUse = links.filter { [.otherLink, .conflict].contains($0.link.state) }
                guard inUse.isEmpty else {
                    let replaceable = inUse.contains { $0.link.state == .otherLink }
                    throw ControlFailure(
                        .destinationExists,
                        "Another skill is in use at \(inUse.map(\.link.displayPath).joined(separator: ", ")). \(AppIdentity.current.name) left it unchanged.",
                        hint: replaceable
                            ? "If the user agrees, run the same command with --replace to replace the links. A folder that isn't a link stays: move or rename it, or pass --dir with another skills folder."
                            : "Move or rename the other skill, or pass --dir with another skills folder.",
                        details: .array(results))
                }
            }
            if options.json { Output.write(.success(.array(results))) }
        }
    }
}
