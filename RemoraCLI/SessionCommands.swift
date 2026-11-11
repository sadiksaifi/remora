import ArgumentParser
import Foundation
import RemoraControl

struct SessionOptions: ParsableArguments {
    @Option(help: "Session attempt UUID or exact connection name. Defaults to REMORA_SESSION, then the only open tab.") var session: String?
    var target: String? { session ?? ProcessInfo.processInfo.environment["REMORA_SESSION"] }
}

struct ConnectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Connect, or reuse the open session, and wait for the first frame.",
        discussion: "The result's reused is true when the session was already open. Its session value is the --session to pass to other commands.")
    @OptionGroup var options: CommonOptions
    @Argument(help: "Saved connection name or UUID.") var connection: String
    @Flag(help: "Leave the selected tab unchanged and do not show the window.") var background = false
    @Flag(help: "Return without waiting for the first frame.") var noWait = false
    @Option(
        help: """
            Use fit (follow the window) or WIDTHxHEIGHT for this attempt only.
            The saved connection is unchanged.
            Each side must be 200 to 8192 pixels, with an even width.
            RDP starts at the saved resolution, or 1920x1080 for fit-to-window connections.
            VNC starts at the server's size; use session resize to request other dimensions.
            """) var resolution: String?
    @MainActor func run() async throws {
        var args: [String: ControlValue] = ["connection": .string(connection), "background": .bool(background), "noWait": .bool(noWait)]
        if let resolution {
            _ = try ControlResolution(resolution)
            args["resolution"] = .string(resolution)
        }
        try await options.execute(.init(command: "connect", arguments: args), defaultTimeout: "30s")
    }
}

struct SessionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session", abstract: "Inspect and control session tabs.",
        subcommands: [List.self, Get.self, Show.self, Disconnect.self, Reconnect.self, Close.self, Resize.self, Stop.self, Resume.self])
    @OptionGroup var options: CommonOptions
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the open session tabs.")
        @OptionGroup var options: CommonOptions
        @MainActor func run() async throws { try await options.execute(.init(command: "session.list")) }
    }
    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one session: its state, who holds control, its desktop size and its latest frame.")
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @MainActor func run() async throws { try await options.execute(.init(command: "session.get", session: target.target)) }
    }
    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Select the session's tab and bring Remora to the front.")
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @MainActor func run() async throws { try await options.execute(.init(command: "session.show", session: target.target)) }
    }
    struct Disconnect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Disconnect the session and keep its tab for session reconnect.")
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @MainActor func run() async throws { try await options.execute(.init(command: "session.disconnect", session: target.target)) }
    }
    struct Close: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Disconnect the session and close its tab. It fails while the user holds control.")
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @MainActor func run() async throws { try await options.execute(.init(command: "session.close", session: target.target)) }
    }
    struct Reconnect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Connect a disconnected session again and wait for the first frame.")
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @Flag(help: "Return without waiting for the first frame.") var noWait = false
        @MainActor func run() async throws {
            try await options.execute(.init(command: "session.reconnect", session: target.target, arguments: ["noWait": .bool(noWait)]), defaultTimeout: "30s")
        }
    }
    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Release agent control. The next input command attaches again.")
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @Flag(help: "Release agent control in every tab.") var all = false
        mutating func validate() throws {
            if all, target.session != nil { throw ValidationError("Use --all without --session.") }
        }
        @MainActor func run() async throws {
            try await options.execute(
                .init(
                    command: "session.stop", session: all ? nil : target.target,
                    arguments: ["all": .bool(all)]))
        }
    }
    struct Resume: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check that the agent may send input. It fails while the user holds control, and only the user can resume, from Remora.")
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @MainActor func run() async throws {
            try await options.execute(.init(command: "session.resume", session: target.target))
        }
    }
    struct Resize: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Ask the remote desktop to change size. Servers without dynamic resizing refuse.")
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @Argument(help: "WIDTHxHEIGHT, 200 to 8192 pixels per side with an even width.") var resolution: String
        @MainActor func run() async throws {
            _ = try ControlResolution(resolution, allowFit: false)
            try await options.execute(.init(command: "session.resize", session: target.target, arguments: ["resolution": .string(resolution)]))
        }
    }
}

struct WaitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait", abstract: "Wait for a session state, frame, or completed recording.",
        discussion: """
            STATE               RETURNS WHEN
            connected           the session shows a desktop
            disconnected        the session has ended
            frame               a frame newer than --after, or the first frame
            resumed             the user handed control back to the agent
            recording-finished  a stopped recording's file is complete

            A frame-timeout failure means the screen did not change before the deadline.
            """)
    enum State: String, CaseIterable, ExpressibleByArgument {
        case connected, disconnected, frame, resumed
        case recordingFinished = "recording-finished"
    }
    @OptionGroup var options: CommonOptions
    @OptionGroup var target: SessionOptions
    @Option(name: .customLong("for"), help: "The state to wait for.") var state: State
    @Option(help: "Wait for a frame strictly newer than this revision, such as a screenshot's frame value. Requires --for frame.") var after: Int?
    mutating func validate() throws {
        if let after, after < 0 || state != .frame { throw ValidationError("--after requires --for frame and a nonnegative revision.") }
    }
    @MainActor func run() async throws {
        var arguments: [String: ControlValue] = ["for": .string(state.rawValue)]
        if let after { arguments["after"] = .number(Double(after)) }
        try await options.execute(.init(command: "wait", session: target.target, arguments: arguments))
    }
}
