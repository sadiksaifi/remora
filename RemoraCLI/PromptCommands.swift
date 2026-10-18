import ArgumentParser
import RemoraControl

struct PromptCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "prompt", abstract: "Answer credentials and certificate requests.",
        subcommands: [List.self, Get.self, Respond.self])
    @OptionGroup var options: CommonOptions
    struct List: AsyncParsableCommand {
        @OptionGroup var options: CommonOptions
        @MainActor func run() async throws { try await options.execute(.init(command: "prompt.list")) }
    }
    struct Get: AsyncParsableCommand {
        @OptionGroup var options: CommonOptions
        @Argument var prompt: String
        @MainActor func run() async throws { try await options.execute(.init(command: "prompt.get", arguments: ["prompt": .string(prompt)])) }
    }
    struct Respond: AsyncParsableCommand {
        enum Action: String, ExpressibleByArgument { case connect, cancel }
        @OptionGroup var options: CommonOptions
        @Argument var prompt: String
        @Argument var action: Action
        @Option var set: [String] = []
        @Flag var passwordStdin = false
        @Flag var clearPassword = false
        mutating func validate() throws {
            if passwordStdin && clearPassword { throw ValidationError("Choose --password-stdin or --clear-password.") }
            if action == .cancel && (!set.isEmpty || passwordStdin || clearPassword) { throw ValidationError("Cancel accepts no credential fields.") }
        }
        @MainActor func run() async throws {
            var args: [String: ControlValue] = ["prompt": .string(prompt), "action": .string(action.rawValue)]
            for field in set {
                let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, ["username", "domain", "remember"].contains(String(pair[0])), args[String(pair[0])] == nil else {
                    throw ValidationError("Use --set username=VALUE, domain=VALUE or remember=true|false once each.")
                }
                args[String(pair[0])] = .string(String(pair[1]))
            }
            if passwordStdin { args["password"] = .string(try await readPassword()) }
            if clearPassword { args["clearPassword"] = .bool(true) }
            try await options.execute(.init(command: "prompt.respond", arguments: args))
        }
    }
}
