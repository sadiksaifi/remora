import ArgumentParser
import RemoraControl

struct PromptCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prompt", abstract: "Answer credentials and certificate requests.",
        subcommands: [List.self, Get.self, Respond.self])
    @OptionGroup var options: CommonOptions
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the pending credentials and certificate prompts.")
        @OptionGroup var options: CommonOptions
        @MainActor func run() async throws { try await options.execute(.init(command: "prompt.list")) }
    }
    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one pending prompt: the fields it asks for, or the certificate and its fingerprint.")
        @OptionGroup var options: CommonOptions
        @Argument(help: "Prompt UUID from prompt list.") var prompt: String
        @MainActor func run() async throws { try await options.execute(.init(command: "prompt.get", arguments: ["prompt": .string(prompt)])) }
    }
    struct Respond: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Answer a prompt. connect submits the credentials or trusts the certificate; cancel rejects it.")
        enum Action: String, ExpressibleByArgument { case connect, cancel }
        @OptionGroup var options: CommonOptions
        @Argument(help: "Prompt UUID from prompt list.") var prompt: String
        @Argument(help: "connect to accept, or cancel to reject the prompt.") var action: Action
        @Option(help: "Set username=VALUE, domain=VALUE or remember=true|false. Repeat once per field.") var set: [String] = []
        @Flag(help: "Read the password from UTF-8 stdin, removing one trailing line ending.") var passwordStdin = false
        @Flag(help: "Use an empty password for this prompt.") var clearPassword = false
        mutating func validate() throws {
            if passwordStdin && clearPassword { throw ValidationError("Choose --password-stdin or --clear-password.") }
            if action == .cancel && (!set.isEmpty || passwordStdin || clearPassword) { throw ValidationError("Cancel accepts no credential fields.") }
        }
        @MainActor func run() async throws {
            let deadline = try options.deadline(for: "prompt.respond")
            var args: [String: ControlValue] = ["prompt": .string(prompt), "action": .string(action.rawValue)]
            for field in set {
                let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, ["username", "domain", "remember"].contains(String(pair[0])), args[String(pair[0])] == nil else {
                    throw ValidationError("Use --set username=VALUE, domain=VALUE or remember=true|false once each.")
                }
                args[String(pair[0])] = .string(String(pair[1]))
            }
            if passwordStdin { args["password"] = .string(try await readPassword(until: deadline)) }
            if clearPassword { args["clearPassword"] = .bool(true) }
            try await options.execute(.init(command: "prompt.respond", arguments: args), deadline: deadline)
        }
    }
}
