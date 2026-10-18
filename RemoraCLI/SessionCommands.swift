import ArgumentParser
import Foundation
import RemoraControl

struct SessionOptions: ParsableArguments {
    @Option(help: "Session attempt UUID or exact connection name. Defaults to REMORA_SESSION, then the only open tab.") var session: String?
    var target: String? { session ?? ProcessInfo.processInfo.environment["REMORA_SESSION"] }
}

struct ConnectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "connect", abstract: "Connect and wait for the first frame.")
    @OptionGroup var options: CommonOptions
    @Argument var connection: String
    @Flag var background = false
    @Flag var noWait = false
    @Option var resolution: String?
    @MainActor func run() async throws {
        var args: [String: ControlValue] = ["connection": .string(connection), "background": .bool(background), "noWait": .bool(noWait)]
        if let resolution { _ = try ControlResolution(resolution); args["resolution"] = .string(resolution) }
        try await options.execute(.init(command: "connect", arguments: args), defaultTimeout: "30s")
    }
}

struct SessionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "session", abstract: "Inspect and control session tabs.",
        subcommands: [List.self, Get.self, Show.self, Disconnect.self, Reconnect.self, Close.self, Resize.self])
    @OptionGroup var options: CommonOptions
    struct List: AsyncParsableCommand {
        @OptionGroup var options: CommonOptions
        @MainActor func run() async throws { try await options.execute(.init(command: "session.list")) }
    }
    struct Get: AsyncParsableCommand {
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @MainActor func run() async throws { try await options.execute(.init(command: "session.get", session: target.target)) }
    }
    struct Show: AsyncParsableCommand {
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @MainActor func run() async throws { try await options.execute(.init(command: "session.show", session: target.target)) }
    }
    struct Disconnect: AsyncParsableCommand {
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @MainActor func run() async throws { try await options.execute(.init(command: "session.disconnect", session: target.target)) }
    }
    struct Close: AsyncParsableCommand {
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @MainActor func run() async throws { try await options.execute(.init(command: "session.close", session: target.target)) }
    }
    struct Reconnect: AsyncParsableCommand {
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @Flag var noWait = false
        @MainActor func run() async throws {
            try await options.execute(.init(command: "session.reconnect", session: target.target, arguments: ["noWait": .bool(noWait)]), defaultTimeout: "30s")
        }
    }
    struct Resize: AsyncParsableCommand {
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @Argument var resolution: String
        @MainActor func run() async throws {
            _ = try ControlResolution(resolution, allowFit: false)
            try await options.execute(.init(command: "session.resize", session: target.target, arguments: ["resolution": .string(resolution)]))
        }
    }
}

struct WaitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "wait", abstract: "Wait for a session to connect or disconnect.")
    enum State: String, ExpressibleByArgument { case connected, disconnected }
    @OptionGroup var options: CommonOptions
    @OptionGroup var target: SessionOptions
    @Option(name: .customLong("for")) var state: State
    @MainActor func run() async throws {
        try await options.execute(.init(command: "wait", session: target.target, arguments: ["for": .string(state.rawValue)]))
    }
}
