import AppKit
import ArgumentParser
import RemoraControl

@main
enum RemoraEntry {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["help", "agent"] {
            print("""
                Connect, screenshot, act, wait, verify.
                Replace C with a saved connection UUID or exact name.
                Replace S, I and F with the returned session UUID, image receipt and frame revision.

                1. Connect: remora connect C --background --json
                   Save result.session as S. Connect waits for the first frame.
                2. Observe: remora screenshot --session S --json
                   Read the PNG at result.path. Save result.image as I and result.frame as F.
                3. Act on what you saw: remora click 100 200 --image I --session S --json
                   With --image, coordinates use that screenshot's pixels from the top-left.
                   Send text with remora type --text "Hello" --session S --json.
                4. Wait: remora wait --for frame --after F --session S --timeout 10s --json
                   A newer frame does not prove the remote app finished the action.
                5. Verify: remora screenshot --session S --json
                   Inspect the result before choosing the next action.

                Refusals:
                user-active: The human took over. Stop sending input.
                  Wait with remora wait --for resumed --session S --timeout 1m --json.
                  If it times out, keep waiting for them. Never resume the session yourself.
                  After they Resume, take a new screenshot before sending input.
                observation-required: Take a new screenshot before sending input.
                input-busy: Another input command is running on this session, or control is transferring.
                  Wait for it to finish. Observe again before retrying.

                Stop Agent Control is a soft stop. Your next input command reattaches.
                To leave control with the human, stop issuing input.
                Input success acknowledges protocol submission. Verify the remote result with a screenshot.
                After a timeout or lost reply, inspect state and screenshot before repeating an action.
                Use --json for result and error envelopes. Use remora COMMAND --help for command details.
                """)
            return
        }
        let task = Task { () -> Int32 in
            do {
                var command = try RemoraCommand.parseAsRoot(arguments)
                if var command = command as? any AsyncParsableCommand { try await command.run() }
                else { try command.run() }
                return 0
            } catch let failure as ControlFailure {
                return report(failure, json: arguments.contains("--json"))
            } catch {
                let code = RemoraCommand.exitCode(for: error)
                if code == .success { RemoraCommand.exit(withError: error) }
                return report(ControlFailure(.invalidArgument, RemoraCommand.fullMessage(for: error)),
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
        if json { Output.write(.failure(failure)) }
        else {
            let hint = failure.hint.isEmpty ? "" : "\n\(failure.hint)"
            FileHandle.standardError.write(Data("\(failure.message)\(hint)\n".utf8))
        }
        return failure.code.exitCode
    }
}

struct RemoraCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remora",
        abstract: "Control the Remora desktop app.",
        discussion: "Run 'remora help agent' for the agent guide. Durations accept ms, s or m; bare numbers are seconds.",
        subcommands: [Capabilities.self, AppCommand.self, ConnectionCommand.self, ConnectCommand.self, SessionCommand.self, PromptCommand.self, WaitCommand.self, ClipboardCommand.self, SettingsCommand.self, ScreenshotCommand.self, RecordingCommand.self, EventsCommand.self, MoveCommand.self, ClickCommand.self, DragCommand.self, ScrollCommand.self, TypeCommand.self, KeyCommand.self, InputCommand.self])
    @OptionGroup var options: CommonOptions
}

struct CommonOptions: ParsableArguments {
    @Flag(help: "Print one JSON result or error envelope.") var json = false
    @Option(name: .long, help: "Command deadline, separate from the 10-second startup deadline.") var timeout: String?

    mutating func validate() throws { if let timeout { _ = try CommandTimeout(timeout) } }

    @MainActor func execute(_ request: ControlRequest, launch: Bool = true, defaultTimeout: String = "10s") async throws {
        let seconds = try CommandTimeout(timeout ?? defaultTimeout).seconds
        let bounded = ControlRequest(command: request.command, session: request.session, timeout: seconds, arguments: request.arguments)
        let result = try await ApplicationClient().request(bounded, launch: launch, timeout: seconds + 1)
        switch result {
        case .success: Output.write(result, json: json)
        case .failure(let failure): throw failure
        }
    }
}

struct Capabilities: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List commands, or inspect negotiated input support with --session.")
    @OptionGroup var options: CommonOptions

    @OptionGroup var target: SessionOptions

    @MainActor func run() async throws {
        if let session = target.target {
            try await options.execute(.init(command: "capabilities", session: session))
            return
        }
        Output.write(.success(.object([
            "commands": .array(["help", "help agent", "capabilities", "app status", "app show", "app hide", "app close", "app quit", "connection list", "connection get", "connection create", "connection update", "connection duplicate", "connection delete", "connection password set", "connection password clear", "connect", "session list", "session get", "session show", "session disconnect", "session reconnect", "session close", "session resize", "session stop", "session resume", "prompt list", "prompt get", "prompt respond", "wait", "clipboard get", "clipboard set", "settings get", "settings set", "settings reset", "settings permission", "settings cli get", "settings cli repair", "settings cli uninstall", "screenshot", "recording start", "recording get", "recording stop", "events", "move", "click", "drag", "scroll", "type", "key", "input"].map(ControlValue.string)),
            "protocols": .array([.string("rdp")])
        ])), json: options.json)
    }
}

struct AppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "app", abstract: "Inspect or control the app.",
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
            guard running else { print("Remora is not running."); return }
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
