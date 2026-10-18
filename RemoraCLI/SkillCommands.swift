import ArgumentParser
import Foundation
import RemoraControl

extension AgentSkill.Agent: @retroactive ExpressibleByArgument {}

struct SkillCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "skill", abstract: "Link the bundled agent skill into AI agents' skills folders.",
        subcommands: [Path.self, Install.self, Uninstall.self])

    static var skill: AgentSkill { AgentSkill(app: ApplicationClient.bundleURL) }

    struct Path: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the bundled skill folder.")
        @OptionGroup var options: CommonOptions
        func run() {
            if options.json { Output.write(.success(.object(["path": .string(skill.folder.path)]))) } else { print(skill.folder.path) }
        }
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Link the skill as remora in each detected agent's skills folder.")
        @OptionGroup var targets: Targets
        func run() throws { try targets.apply(install: true) }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove the remora links that point to this app's skill.")
        @OptionGroup var targets: Targets
        func run() throws { try targets.apply(install: false) }
    }

    struct Targets: ParsableArguments {
        @OptionGroup var options: CommonOptions
        @Option(help: "Use only this agent's skills folder.") var agent: AgentSkill.Agent?
        @Option(help: "Use this skills folder instead.") var dir: String?

        func validate() throws {
            if agent != nil, dir != nil { throw ValidationError("Choose --agent or --dir.") }
        }

        /// Never replaces or removes a remora skill that is not this app's link.
        func apply(install: Bool) throws {
            let links: [(name: String, link: CommandLineTool)]
            if let dir {
                links = [("Folder", skill.link(in: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)))]
            } else {
                links = (agent.map { [$0] } ?? AgentSkill.Agent.allCases.filter(\.isDetected)).map { ($0.name, skill.link(for: $0)) }
                guard !links.isEmpty else {
                    throw ControlFailure(.invalidArgument, "No supported agent was found.", hint: "Use --dir with your agent's user skills folder.")
                }
            }
            var results: [ControlValue] = []
            for (name, link) in links {
                do {
                    if link.state != .conflict {
                        if install { try link.install() } else if link.state != .notInstalled { try link.uninstall() }
                    }
                } catch { throw ControlFailure(.ioFailed, error.localizedDescription) }
                results.append(.object(["agent": .string(name), "path": .string(link.link.path), "state": .string(link.state.rawValue)]))
                if !options.json { print("\(name): \(link.state == .conflict ? "in use by another skill" : link.state == .notInstalled ? "not installed" : "installed") at \(link.displayPath)") }
            }
            let inUse = links.filter { $0.link.state == .conflict }.map(\.link.displayPath)
            guard inUse.isEmpty else {
                throw ControlFailure(.destinationExists, "Another skill is in use at \(inUse.joined(separator: ", ")). Remora left it unchanged.",
                                     details: .array(results))
            }
            if options.json { Output.write(.success(.array(results))) }
        }
    }
}
