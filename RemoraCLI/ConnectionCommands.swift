import ArgumentParser
import Foundation
import RemoraControl

struct ConnectionFields: ParsableArguments {
    @Option(help: "Remote hostname or IP address. Required when creating a connection.") var host: String?
    @Option(help: "Saved connection name.") var name: String?
    @Option(help: "Protocol: rdp or vnc. Defaults to rdp when creating a connection.") var kind: String?
    @Option(help: "Remote port, 1 to 65535. Defaults to 3389 for RDP and 5900 for VNC.") var port: Int?
    @Option(help: "Remote account username.") var username: String?
    @Option(help: "Remote account domain.") var domain: String?
    @Option(help: "Saved resolution: fit or WIDTHxHEIGHT, 200 to 8192 pixels per side with an even width. VNC starts at the server's size.") var resolution:
        String?
    @Option(
        help:
            "VNC mode: standard, or apple for Apple Screen Sharing's encrypted connection and faster, lossy encoding (Macs only; the Mac must prove that it knows the account's password)."
    ) var vncMode: String?
    @Flag(help: "Read the password from UTF-8 stdin, removing one trailing line ending.") var passwordStdin = false

    func arguments() async throws -> [String: ControlValue] {
        if let resolution { _ = try ControlResolution(resolution) }
        if let port, !(1...65535).contains(port) { throw ValidationError("Port must be 1 to 65535.") }
        if let kind, !["rdp", "vnc"].contains(kind) { throw ValidationError("Protocol must be rdp or vnc.") }
        if let vncMode, !["standard", "apple"].contains(vncMode) { throw ValidationError("VNC mode must be standard or apple.") }
        var result: [String: ControlValue] = [:]
        for (key, value) in [
            ("kind", kind), ("host", host), ("name", name), ("username", username), ("domain", domain), ("resolution", resolution), ("vncMode", vncMode),
        ] {
            if let value { result[key] = .string(value) }
        }
        if let port { result["port"] = .number(Double(port)) }
        if passwordStdin { result["password"] = .string(try await readPassword()) }
        return result
    }
}

func readPassword() async throws -> String {
    try PasswordInput.decode(try await readStandardInput())
}

/// Reads piped text or JSON. A terminal fails at once, because a command that waits for typed input looks hung to an agent.
func readPipedInput() async throws -> Data {
    guard isatty(STDIN_FILENO) == 0 else { throw ControlFailure(.invalidArgument, "Pipe the input on stdin.") }
    return try await readStandardInput()
}

func readStandardInput() async throws -> Data {
    let input = FileHandle.standardInput
    let chunks = AsyncThrowingStream<Data, any Error>(bufferingPolicy: .bufferingOldest(16)) { continuation in
        continuation.onTermination = { _ in input.readabilityHandler = nil }
        input.readabilityHandler = { handle in
            do {
                let chunk = try handle.read(upToCount: 65_536) ?? Data()
                if chunk.isEmpty {
                    continuation.finish()
                } else if case .dropped = continuation.yield(chunk) {
                    continuation.finish(throwing: ControlFailure(.invalidArgument, "Stdin exceeds the read buffer."))
                }
            } catch {
                continuation.finish(throwing: ControlFailure(.ioFailed, "Could not read stdin."))
            }
        }
    }
    defer { input.readabilityHandler = nil }
    var data = Data()
    for try await chunk in chunks {
        data.append(chunk)
        guard data.count < 1_048_576 else { throw ControlFailure(.invalidArgument, "Stdin exceeds the request size limit.") }
    }
    if Task.isCancelled { throw ControlFailure(.cancelled, "The command was interrupted.") }
    return data
}

struct ConnectionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connection", abstract: "Manage saved connections.",
        subcommands: [List.self, Get.self, Create.self, Update.self, Duplicate.self, Delete.self])
    @OptionGroup var options: CommonOptions

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List saved connections.")
        @OptionGroup var options: CommonOptions
        @Option(help: "Filter by connection name, host or username.") var search: String?
        @MainActor func run() async throws {
            try await options.execute(.init(command: "connection.list", arguments: search.map { ["search": .string($0)] } ?? [:]))
        }
    }
    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one saved connection, whether it has a saved password, and its open session.")
        @OptionGroup var options: CommonOptions
        @Argument(help: "Saved connection name or UUID.") var connection: String
        @MainActor func run() async throws { try await options.execute(.init(command: "connection.get", arguments: ["connection": .string(connection)])) }
    }
    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Save a new connection. It does not connect.")
        @OptionGroup var options: CommonOptions
        @OptionGroup var fields: ConnectionFields
        mutating func validate() throws { guard fields.host != nil else { throw ValidationError("--host is required.") } }
        @MainActor func run() async throws { try await options.execute(.init(command: "connection.create", arguments: try await fields.arguments())) }
    }
    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change a saved connection or its saved password. Fields you leave out keep their values.")
        @OptionGroup var options: CommonOptions
        @OptionGroup var fields: ConnectionFields
        @Argument(help: "Saved connection name or UUID.") var connection: String
        @Flag(help: "Remove the saved password.") var clearPassword = false
        mutating func validate() throws {
            if clearPassword && fields.passwordStdin { throw ValidationError("Choose --password-stdin or --clear-password.") }
        }
        @MainActor func run() async throws {
            var args = try await fields.arguments()
            args["connection"] = .string(connection)
            args["clearPassword"] = .bool(clearPassword)
            try await options.execute(.init(command: "connection.update", arguments: args))
        }
    }
    struct Duplicate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Copy a saved connection, including its saved password.")
        @OptionGroup var options: CommonOptions
        @Argument(help: "Saved connection name or UUID.") var connection: String
        @Option(help: "Saved connection name.") var name: String?
        @MainActor func run() async throws {
            var args: [String: ControlValue] = ["connection": .string(connection)]
            if let name { args["name"] = .string(name) }
            try await options.execute(.init(command: "connection.duplicate", arguments: args))
        }
    }
    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a saved connection and its saved password.")
        @OptionGroup var options: CommonOptions
        @Argument(help: "Saved connection name or UUID.") var connection: String
        @MainActor func run() async throws { try await options.execute(.init(command: "connection.delete", arguments: ["connection": .string(connection)])) }
    }
}
