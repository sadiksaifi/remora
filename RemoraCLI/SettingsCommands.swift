import ArgumentParser
import Foundation
import RemoraControl

struct SettingsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settings", abstract: "Read and change Remora settings.",
        subcommands: [Get.self, Set.self, Reset.self, Permission.self, CLI.self])
    @OptionGroup var options: CommonOptions

    struct Get: AsyncParsableCommand {
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
        @OptionGroup var options: CommonOptions
        @Argument(help: "Settings key. Omit to reset all settings.") var key: String?
        @MainActor func run() async throws {
            try await options.execute(.init(command: "settings.reset", arguments: key.map { ["key": .string($0)] } ?? [:]))
        }
    }
    struct Permission: AsyncParsableCommand {
        @OptionGroup var options: CommonOptions
        @Flag(help: "Open Accessibility settings in System Settings.") var open = false
        @MainActor func run() async throws {
            try await options.execute(.init(command: "settings.permission", arguments: ["open": .bool(open)]))
        }
    }
    struct CLI: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "cli", subcommands: [Get.self, Repair.self, Uninstall.self])
        @OptionGroup var options: CommonOptions
        struct Get: AsyncParsableCommand {
            @OptionGroup var options: CommonOptions
            @MainActor func run() async throws {
                let helper = ApplicationClient.bundleURL.appending(path: "Contents/Helpers/remora")
                Output.write(.success(CommandLineTool(target: helper).status), json: options.json)
            }
        }
        struct Repair: AsyncParsableCommand {
            @OptionGroup var options: CommonOptions
            @MainActor func run() async throws { try await options.execute(.init(command: "settings.cli.repair")) }
        }
        struct Uninstall: AsyncParsableCommand {
            @OptionGroup var options: CommonOptions
            @MainActor func run() async throws { try await options.execute(.init(command: "settings.cli.uninstall")) }
        }
    }
}
