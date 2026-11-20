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
    struct CLI: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "cli", abstract: "Inspect or change the \(AppIdentity.current.commandName) link in ~/.local/bin.",
            subcommands: [Get.self, Repair.self, Uninstall.self])
        @OptionGroup var options: CommonOptions
        struct Get: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Report whether \(CommandLineTool().displayPath) is installed and points to this copy of \(AppIdentity.current.name).",
                discussion: linkStates(fix: "\(AppIdentity.current.commandName) settings cli repair"))
            @OptionGroup var options: CommonOptions
            @MainActor func run() async throws {
                Output.write(.success(CommandLineTool().status), json: options.json)
            }
        }
        struct Repair: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Point \(CommandLineTool().displayPath) at this copy of \(AppIdentity.current.name), and create it if it's missing.",
                discussion: readOnlyDiscussion)
            @OptionGroup var options: CommonOptions
            @Flag(help: "Also replace a link to another app or tool. A file that isn't a link is never replaced.") var replace = false
            @MainActor func run() async throws {
                try await options.execute(.init(command: "settings.cli.repair", arguments: ["replace": .bool(replace)]))
            }
        }
        struct Uninstall: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Remove \(CommandLineTool().displayPath) when it points to a copy of \(AppIdentity.current.name).")
            @OptionGroup var options: CommonOptions
            @MainActor func run() async throws { try await options.execute(.init(command: "settings.cli.uninstall")) }
        }
    }
}
