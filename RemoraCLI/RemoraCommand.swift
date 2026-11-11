import AppKit
import ArgumentParser
import RemoraControl

@main
enum RemoraEntry {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["help", "agent"] {
            let file = AgentSkill(app: ApplicationClient.bundleURL).folder.appending(path: "SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                Darwin.exit(report(ControlFailure(.ioFailed, "The agent guide is missing at \(file.path)."), json: false))
            }
            print(text.replacing(/(?s)\A---\n.*?\n---\n+/, with: ""))
            print("If the user asks you to install this guide as a skill, run: remora skill install --dir <your user skills folder>")
            return
        }
        // Build-time drift check from project.yml. Every `remora ...` command in SKILL.md and in the failure hints
        // must still parse, and every command needs a description, because agents learn the CLI from its help.
        // Placeholders such as C, S and P stand in as 1, which every argument accepts.
        if arguments.count == 2, arguments[0] == "__check-help" {
            var failed = false
            let texts = [try! String(contentsOfFile: arguments[1], encoding: .utf8)] + ControlFailure.Code.allCases.map(\.hint)
            for line in texts.flatMap({ $0.matches(of: /`remora ([^`]*)`/) }) {
                let words = line.1.matches(of: /"[^"]*"|\S+/).map { word in
                    word.0.count == 1 && word.0.first!.isUppercase ? "1" : word.0.trimmingCharacters(in: ["\""])
                }
                do { _ = try RemoraCommand.parseAsRoot(words) } catch  where RemoraCommand.exitCode(for: error) == .success {} catch {
                    print("\(arguments[1]): error: `remora \(line.1)` does not parse: \(RemoraCommand.message(for: error))")
                    failed = true
                }
            }
            for command in RemoraCommand.tree where command.type.configuration.abstract.isEmpty {
                print("\(arguments[1]): error: `remora \(command.path)` has no description.")
                failed = true
            }
            Darwin.exit(failed ? 1 : 0)
        }
        let task = Task { () -> Int32 in
            do {
                var command = try RemoraCommand.parseAsRoot(arguments)
                if var command = command as? any AsyncParsableCommand { try await command.run() } else { try command.run() }
                return 0
            } catch let failure as ControlFailure {
                return report(failure, json: arguments.contains("--json"))
            } catch {
                let code = RemoraCommand.exitCode(for: error)
                if code == .success { RemoraCommand.exit(withError: error) }
                return report(
                    ControlFailure(.invalidArgument, RemoraCommand.fullMessage(for: error)),
                    json: arguments.contains("--json"))
            }
        }
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { task.cancel() }
        interrupt.resume()
        let code = await task.value
        interrupt.cancel()
        Darwin.exit(code)
    }

    private static func report(_ failure: ControlFailure, json: Bool) -> Int32 {
        if json {
            Output.write(.failure(failure))
        } else {
            let hint = failure.hint.isEmpty ? "" : "\n\(failure.hint)"
            FileHandle.standardError.write(Data("\(failure.message)\(hint)\n".utf8))
        }
        return failure.code.exitCode
    }
}

struct RemoraCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remora",
        abstract: "Control the Remora app. AI agents: run 'remora help agent' first.",
        subcommands: [
            Capabilities.self, AppCommand.self, ConnectionCommand.self, ConnectCommand.self, SessionCommand.self, PromptCommand.self, WaitCommand.self,
            ClipboardCommand.self, SettingsCommand.self, ScreenshotCommand.self, RecordingCommand.self, EventsCommand.self, MoveCommand.self, ClickCommand.self,
            DragCommand.self, ScrollCommand.self, TypeCommand.self, KeyCommand.self, InputCommand.self, SkillCommand.self,
        ])
    @OptionGroup var options: CommonOptions

    /// Every command below the root with its full name, such as `session list`, in help order.
    static let tree: [(path: String, type: any ParsableCommand.Type)] = {
        func walk(_ type: any ParsableCommand.Type, _ prefix: String) -> [(path: String, type: any ParsableCommand.Type)] {
            type.configuration.subcommands.flatMap { child in
                let path = prefix + child._commandName
                return [(path, child)] + walk(child, path + " ")
            }
        }
        return walk(RemoraCommand.self, "")
    }()
}

/// A command's deadline when --timeout is absent. The type states it once, for both the help and the request.
protocol Deadline { static var help: String { get } }
protocol BoundedDeadline: Deadline { static var fallback: String { get } }
extension BoundedDeadline { static var help: String { fallback } }
enum After10s: BoundedDeadline { static let fallback = "10s" }
enum After30s: BoundedDeadline { static let fallback = "30s" }
enum After60s: BoundedDeadline { static let fallback = "60s" }
enum Unbounded: Deadline { static let help = "no deadline" }

typealias CommonOptions = Options<After10s>

struct Options<Default: Deadline>: ParsableArguments {
    @Flag(help: "Print one JSON result or error envelope.") var json = false
    @Option(name: .long, help: "Command deadline, such as 500ms, 10s or 2m. Bare numbers are seconds. Defaults to \(Default.help).") var timeout: String?

    mutating func validate() throws { if let timeout { _ = try CommandTimeout(timeout) } }
}

extension Options where Default: BoundedDeadline {
    var seconds: Double { get throws { try CommandTimeout(timeout ?? Default.fallback).seconds } }

    @MainActor func execute(_ request: ControlRequest, launch: Bool = true) async throws {
        let seconds = try self.seconds
        let bounded = ControlRequest(
            command: request.command, session: request.session, timeout: seconds,
            arguments: request.arguments, agent: AgentName.current)
        let result = try await ApplicationClient().request(bounded, launch: launch, timeout: seconds + 1)
        switch result {
        case .success: Output.write(result, json: json)
        case .failure(let failure): throw failure
        }
    }
}

struct Capabilities: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List commands. With --session, list the key names and input features that session supports.")
    @OptionGroup var options: CommonOptions

    @OptionGroup var target: SessionOptions

    @MainActor func run() async throws {
        if let session = target.target {
            try await options.execute(.init(command: "capabilities", session: session))
            return
        }
        Output.write(
            .success(
                .object([
                    "commands": .array(
                        (["help", "help agent"] + RemoraCommand.tree.filter { $0.type.configuration.subcommands.isEmpty }.map(\.path)).map(ControlValue.string)),
                    "protocols": .array([.string("rdp"), .string("vnc")]),
                ])), json: options.json)
    }
}

struct AppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app", abstract: "Inspect or control the app.",
        subcommands: [Status.self, Show.self, Hide.self, Close.self, Quit.self])
    @OptionGroup var options: CommonOptions

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Report app status without launching it.")
        @OptionGroup var options: CommonOptions
        @MainActor func run() async throws { try await options.execute(ControlRequest(command: "app.status"), launch: false) }
    }
    struct Show: AsyncParsableCommand {
        enum Page: String, ExpressibleByArgument { case connections, settings }
        static let configuration = CommandConfiguration(abstract: "Show and activate Remora.")
        @OptionGroup var options: CommonOptions
        @Option(help: "Open connections or settings.") var page: Page?
        @MainActor func run() async throws {
            try await options.execute(ControlRequest(command: "app.show", arguments: page.map { ["page": .string($0.rawValue)] } ?? [:]))
        }
    }
    struct Hide: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Hide Remora and preserve its sessions.")
        @OptionGroup var options: CommonOptions
        @MainActor func run() async throws { try await options.execute(ControlRequest(command: "app.hide")) }
    }
    struct Close: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close the main window and preserve its sessions.")
        @OptionGroup var options: CommonOptions
        @MainActor func run() async throws { try await options.execute(ControlRequest(command: "app.close")) }
    }
    struct Quit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Quit without confirmation, disconnecting sessions and finishing recordings.")
        @OptionGroup var options: CommonOptions
        @MainActor func run() async throws { try await options.execute(ControlRequest(command: "app.quit")) }
    }
}

enum Output {
    static func write(_ response: ControlResponse, json: Bool = true) {
        if json {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                FileHandle.standardOutput.write(try encoder.encode(response) + Data([10]))
            } catch {
                FileHandle.standardError.write(Data("Could not encode the command result.\n".utf8))
                Darwin.exit(1)
            }
            return
        }
        guard case .success(let value) = response else { return }
        if case .object(let fields) = value, case .bool(let running) = fields["running"] {
            guard running else {
                print("Remora is not running.")
                return
            }
            let hidden = fields["hidden"] == .bool(true)
            let visible = fields["windowVisible"] == .bool(true)
            print("Remora is running. Main window: \(visible ? "open" : "closed"). App: \(hidden ? "hidden" : "shown").")
        } else if case .object(let fields) = value, case .array(let commands) = fields["commands"] {
            for case .string(let command) in commands { print(command) }
        } else if value == .object([:]) || value == .object(["quitting": .bool(true)]) {
            print("Done.")
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) { print(text) }
        }
    }
}
