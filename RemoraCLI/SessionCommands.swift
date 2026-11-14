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
        abstract: "Open a session, or reuse the one already open, and wait for the first frame.",
        discussion:
            "A disconnected session's tab connects again in place. A session whose frame is black the first time connect waits on it, as while Windows attaches it, gets up to three more seconds to show the desktop. The result's session value is the --session to pass to other commands. Its reused value is true when the tab already existed. A failure after the session starts carries both in error.details. Transport failures include Local Network recovery steps when relevant; a timeout alone does not establish a permission denial."
    )
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
            VNC starts on the server's main display when reported, otherwise its first display.
            Use session displays to list displays and session display to choose one.
            """) var resolution: String?
    @MainActor func run() async throws {
        var args: [String: ControlValue] = ["connection": .string(connection), "background": .bool(background), "noWait": .bool(noWait)]
        if let resolution {
            _ = try ControlResolution(resolution)
            args["resolution"] = .string(resolution)
        }
        try await options.execute(.init(command: "connect", arguments: args))
    }
}

struct SessionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session", abstract: "Inspect and control session tabs.",
        subcommands: [List.self, Get.self, Displays.self, Display.self, Show.self, Disconnect.self, Close.self, Resize.self, Release.self])
    @OptionGroup var options: CommonOptions
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the open session tabs.")
        @OptionGroup var options: CommonOptions
        @MainActor func run() async throws { try await options.execute(.init(command: "session.list")) }
    }
    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a session's state, control owner, selected display, desktop size and latest frame.")
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @MainActor func run() async throws { try await options.execute(.init(command: "session.get", session: target.target)) }
    }
    struct Displays: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the remote displays and the selected and pending display IDs.",
            discussion:
                "Display IDs belong to this session and can change after reconnecting. An empty list means the server has not reported selectable displays.")
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @MainActor func run() async throws { try await options.execute(.init(command: "session.displays", session: target.target)) }
    }
    struct Display: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Choose one remote display and wait for its fresh picture.",
            discussion: """
                Use an ID from session displays. This changes the display shown in the same tab for the user and agents, without activating the tab.
                Pointer coordinates, screenshots and recordings cover only the selected display.
                Input and captures are unavailable while the display changes. Take a new screenshot before sending input afterward.
                """)
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @Argument(help: "Display ID from session displays.") var display: UInt32
        @MainActor func run() async throws {
            try await options.execute(.init(command: "session.display", session: target.target, arguments: ["display": .number(Double(display))]))
        }
    }
    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Select the session's tab and bring Remora to the front.")
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @MainActor func run() async throws { try await options.execute(.init(command: "session.show", session: target.target)) }
    }
    struct Disconnect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Disconnect the session and keep its tab. connect starts it again.")
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
    struct Release: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Hand control back to the user. The next input command takes it again.")
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @Flag(help: "Release agent control in every tab.") var all = false
        mutating func validate() throws {
            if all, target.session != nil { throw ValidationError("Use --all without --session.") }
        }
        @MainActor func run() async throws {
            try await options.execute(
                .init(
                    command: "session.release", session: all ? nil : target.target,
                    arguments: ["all": .bool(all)]))
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
