import ArgumentParser
import Foundation
import RemoraControl

struct ClipboardCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clipboard", abstract: "Read or offer remote clipboard text without accessing the Mac clipboard.",
        discussion: "RDP, standard VNC, and Apple Screen Sharing sessions can exchange plain text.",
        subcommands: [Get.self, Set.self])
    @OptionGroup var options: CommonOptions

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Read the text on the remote clipboard.")
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @MainActor func run() async throws {
            try await options.execute(.init(command: "clipboard.get", session: target.target))
        }
    }
    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Put text on the remote clipboard. To paste it, press key Ctrl+V, or Cmd+V when the remote machine is a Mac.")
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @Option(help: "Remote clipboard text. Without it, the command reads untrimmed UTF-8 text from stdin to EOF.") var text: String?
        @MainActor func run() async throws {
            let value: String
            if let text {
                value = text
            } else {
                guard let decoded = String(data: try await readPipedInput(), encoding: .utf8) else {
                    throw ControlFailure(.invalidArgument, "Clipboard stdin must be UTF-8.")
                }
                value = decoded
            }
            guard !value.utf8.contains(0) else { throw ControlFailure(.invalidArgument, "Clipboard text cannot contain NUL bytes.") }
            try await options.execute(.init(command: "clipboard.set", session: target.target, arguments: ["text": .string(value)]))
        }
    }
}
