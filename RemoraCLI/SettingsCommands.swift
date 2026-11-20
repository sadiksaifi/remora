import ArgumentParser
import Foundation
import RemoraControl

struct SettingsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settings", abstract: "Read and change Remora settings.",
        subcommands: [Get.self, Set.self, Reset.self, Permission.self, CLI.self])
    @OptionGroup var options: CommonOptions

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Read one setting, or all of them.")
        @OptionGroup var options: CommonOptions
        @Argument(help: "Settings key. Omit to read all settings.") var key: String?
        @MainActor func run() async throws {
            try await options.execute(.init(command: "settings.get", arguments: key.map { ["key": .string($0)] } ?? [:]))
        }
    }
    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set a Remora setting.",
            discussion: "Keys and values:\n" + SettingKey.allCases.map { "\($0.rawValue): \($0.valueHelp)." }.joined(separator: "\n"))
        @OptionGroup var options: CommonOptions
        @Argument(help: "Settings key from the list above.") var key: String
        @Argument(help: "Value allowed for this key.") var value: String
        @MainActor func run() async throws {
            try await options.execute(.init(command: "settings.set", arguments: ["key": .string(key), "value": .string(value)]))
        }
    }
    struct Reset: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Reset one setting, or all of them, to the default.")
        @OptionGroup var options: CommonOptions
        @Argument(help: "Settings key. Omit to reset all settings.") var key: String?
        @MainActor func run() async throws {
            try await options.execute(.init(command: "settings.reset", arguments: key.map { ["key": .string($0)] } ?? [:]))
        }
    }
    struct Permission: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Report whether Remora has the macOS Accessibility permission, which captureSystemShortcuts needs.")
        @OptionGroup var options: CommonOptions
        @Flag(help: "Open Accessibility settings in System Settings.") var open = false
        @MainActor func run() async throws {
            try await options.execute(.init(command: "settings.permission", arguments: ["open": .bool(open)]))
        }
    }
    /// Reads and changes the link in this process, so ownership and the read-only refusal apply to the copy that holds this helper,
    /// not to whichever copy of the app is running.
    struct CLI: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "cli", abstract: "Inspect or change the \(AppIdentity.current.commandName) link in ~/.local/bin.",
            subcommands: [Get.self, Repair.self, Uninstall.self])
        @OptionGroup var options: CommonOptions
        /// This copy's helper by its full path, because the command name on PATH may run another copy or another tool.
        static var repairCommand: String { "`'\(CommandLineTool().target.path)' settings cli repair" }

        struct Get: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Report whether \(CommandLineTool().displayPath) is installed and points to this copy of \(AppIdentity.current.name).",
                discussion: linkStates(fix: "\(AppIdentity.current.commandName) settings cli repair"))
            @OptionGroup var options: CommonOptions
            func run() { Output.write(.success(CommandLineTool().status), json: options.json) }
        }
        struct Repair: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Point \(CommandLineTool().displayPath) at this copy of \(AppIdentity.current.name), and create it if it's missing.",
                discussion: """
                    It acts on the copy that contains this helper. When \(CommandLineTool().displayPath) runs another copy or another tool, \
                    run this copy's helper by its full path: \(CommandLineTool().target.path)

                    \(readOnlyDiscussion)
                    """)
            @OptionGroup var options: CommonOptions
            @Flag(help: "Also replace a link to another app or tool. Ask the user first. A file that isn't a link is never replaced.") var replace = false
            func run() throws {
                try CLI.change(json: options.json) {
                    try $0.install(replacingOtherLink: replace)
                } inUse: { otherLink in
                    otherLink
                        ? "Ask the user before you replace it. Then run \(repairCommand) --replace`, or choose Replace… in \(AppIdentity.current.name) Settings."
                        : "After that, run \(repairCommand)`."
                }
            }
        }
        struct Uninstall: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Remove \(CommandLineTool().displayPath) when it points to a copy of \(AppIdentity.current.name).")
            @OptionGroup var options: CommonOptions
            func run() throws {
                try CLI.change(json: options.json) {
                    try $0.uninstall()
                } inUse: { _ in
                    "It isn't \(AppIdentity.current.name)'s link, so there is nothing to uninstall. Leave it unless the user asks to remove it."
                }
            }
        }

        /// Runs `action` on this copy's link and prints the link's status. `inUse` gives the hint for another app's link (true) or a file
        /// (false) at the path.
        static func change(json: Bool, _ action: (CommandLineTool) throws -> Void, inUse: (Bool) -> String) throws {
            let tool = CommandLineTool()
            do {
                try action(tool)
            } catch let failure as CommandLineTool.Failure {
                switch failure {
                case .otherLink: throw ControlFailure(.destinationExists, failure.localizedDescription, hint: inUse(true))
                case .conflict: throw ControlFailure(.destinationExists, failure.localizedDescription, hint: inUse(false))
                case .notInstalled, .readOnlyApp: throw ControlFailure(.invalidArgument, failure.localizedDescription, hint: failure.recoverySuggestion)
                }
            } catch { throw ControlFailure(.ioFailed, error.localizedDescription) }
            Output.write(.success(tool.status), json: json)
        }
    }
}
