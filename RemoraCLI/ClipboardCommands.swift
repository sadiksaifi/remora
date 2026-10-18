import ArgumentParser
import Foundation
import RemoraControl

struct ClipboardCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clipboard", abstract: "Read or offer remote clipboard text without accessing the Mac clipboard.",
        subcommands: [Get.self, Set.self])
    @OptionGroup var options: CommonOptions

    struct Get: AsyncParsableCommand {
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @MainActor func run() async throws {
            try await options.execute(.init(command: "clipboard.get", session: target.target))
        }
    }
    struct Set: AsyncParsableCommand {
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @Option var text: String?
        @Flag(name: .customLong("stdin"), help: "Read untrimmed UTF-8 text to EOF. This is the default.") var readStdin = false
        @MainActor func run() async throws {
            guard text == nil || !readStdin else { throw ControlFailure(.invalidArgument, "Choose --text or --stdin.") }
            let value: String
            if let text { value = text }
            else {
                guard let decoded = String(data: try await readStandardInput(), encoding: .utf8) else {
                    throw ControlFailure(.invalidArgument, "Clipboard stdin must be UTF-8.")
                }
                value = decoded
            }
            guard !value.utf8.contains(0) else { throw ControlFailure(.invalidArgument, "Clipboard text cannot contain NUL bytes.") }
            try await options.execute(.init(command: "clipboard.set", session: target.target, arguments: ["text": .string(value)]))
        }
    }
}
