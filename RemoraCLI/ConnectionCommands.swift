import ArgumentParser
import Foundation
import RemoraControl

struct ConnectionFields: ParsableArguments {
    @Option var host: String?
    @Option var name: String?
    @Option var port: Int?
    @Option var username: String?
    @Option var domain: String?
    @Option var resolution: String?
    @Flag var passwordStdin = false

    func arguments() async throws -> [String: ControlValue] {
        if let resolution { _ = try ControlResolution(resolution) }
        if let port, !(1...65535).contains(port) { throw ValidationError("Port must be 1 to 65535.") }
        var result: [String: ControlValue] = [:]
        for (key, value) in [("host", host), ("name", name), ("username", username), ("domain", domain), ("resolution", resolution)] {
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

func readStandardInput() async throws -> Data {
    let input = FileHandle.standardInput
    let chunks = AsyncThrowingStream<Data, any Error>(bufferingPolicy: .bufferingOldest(16)) { continuation in
        continuation.onTermination = { _ in input.readabilityHandler = nil }
        input.readabilityHandler = { handle in
            do {
                let chunk = try handle.read(upToCount: 65_536) ?? Data()
                if chunk.isEmpty { continuation.finish() }
                else if case .dropped = continuation.yield(chunk) {
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
    static let configuration = CommandConfiguration(commandName: "connection", abstract: "Manage saved connections.",
        subcommands: [List.self, Get.self, Create.self, Update.self, Duplicate.self, Delete.self, Password.self])
    @OptionGroup var options: CommonOptions

    struct List: AsyncParsableCommand {
        @OptionGroup var options: CommonOptions
        @Option var search: String?
        @MainActor func run() async throws {
            try await options.execute(.init(command: "connection.list", arguments: search.map { ["search": .string($0)] } ?? [:]))
        }
    }
    struct Get: AsyncParsableCommand {
        @OptionGroup var options: CommonOptions
        @Argument var connection: String
        @MainActor func run() async throws { try await options.execute(.init(command: "connection.get", arguments: ["connection": .string(connection)])) }
    }
    struct Create: AsyncParsableCommand {
        @OptionGroup var options: CommonOptions
        @OptionGroup var fields: ConnectionFields
        mutating func validate() throws { guard fields.host != nil else { throw ValidationError("--host is required.") } }
        @MainActor func run() async throws { try await options.execute(.init(command: "connection.create", arguments: try await fields.arguments())) }
    }
    struct Update: AsyncParsableCommand {
        @OptionGroup var options: CommonOptions
        @OptionGroup var fields: ConnectionFields
        @Argument var connection: String
        @Flag var clearPassword = false
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
        @OptionGroup var options: CommonOptions
        @Argument var connection: String
        @Option var name: String?
        @MainActor func run() async throws {
            var args: [String: ControlValue] = ["connection": .string(connection)]
            if let name { args["name"] = .string(name) }
            try await options.execute(.init(command: "connection.duplicate", arguments: args))
        }
    }
    struct Delete: AsyncParsableCommand {
        @OptionGroup var options: CommonOptions
        @Argument var connection: String
        @MainActor func run() async throws { try await options.execute(.init(command: "connection.delete", arguments: ["connection": .string(connection)])) }
    }
    struct Password: AsyncParsableCommand {
        static let configuration = CommandConfiguration(subcommands: [Set.self, Clear.self])
        @OptionGroup var options: CommonOptions
        struct Set: AsyncParsableCommand {
            @OptionGroup var options: CommonOptions
            @Argument var connection: String
            @Flag var passwordStdin = false
            mutating func validate() throws { guard passwordStdin else { throw ValidationError("--password-stdin is required.") } }
            @MainActor func run() async throws {
                try await options.execute(.init(command: "connection.password.set", arguments: ["connection": .string(connection), "password": .string(try await readPassword())]))
            }
        }
        struct Clear: AsyncParsableCommand {
            @OptionGroup var options: CommonOptions
            @Argument var connection: String
            @MainActor func run() async throws { try await options.execute(.init(command: "connection.password.clear", arguments: ["connection": .string(connection)])) }
        }
    }
}
