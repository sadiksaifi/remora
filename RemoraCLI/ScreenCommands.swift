import ArgumentParser
import Foundation
import RemoraControl

struct ScreenshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot", abstract: "Capture a current remote desktop PNG, including hidden sessions.",
        discussion: """
            The result's path is the saved PNG. Pass its image value as --image to pointer commands, \
            and its frame value to wait --after.
            """)
    @OptionGroup var options: CommonOptions
    @OptionGroup var target: SessionOptions
    @Option(help: "Save to this unused path, or write raw PNG bytes with -. Defaults to the configured save folder.") var output: String?
    @Option(help: "Crop X,Y,W,H in remote pixels from the top-left.") var region: String?
    @Option(help: "Fit within WxH without upscaling.") var maxSize: String?

    mutating func validate() throws {
        if output == "-", options.json { throw ValidationError("--output - cannot be combined with --json.") }
    }

    @MainActor func run() async throws {
        var arguments: [String: ControlValue] = [:]
        if let output { arguments["output"] = .string(output == "-" ? output : absoluteCapturePath(output)) }
        if let region { arguments["region"] = .string(region) }
        if let maxSize { arguments["maxSize"] = .string(maxSize) }
        let request = ControlRequest(command: "screenshot", session: target.target, arguments: arguments)
        guard output == "-" else {
            try await options.execute(request)
            return
        }
        let seconds = try options.seconds(for: request.command)
        let client = ControlClient(endpoint: try ControlEndpoint())
        try await ApplicationClient().prepare(client)
        let bounded = ControlRequest(command: request.command, session: request.session, timeout: seconds, arguments: arguments)
        let (response, png) = try await client.screenshot(bounded, timeout: seconds + 1)
        if case .failure(let failure) = response { throw failure }
        try FileHandle.standardOutput.write(contentsOf: png)
    }
}

struct RecordingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recording", abstract: "Record remote desktop video to a MOV file.", subcommands: [Start.self, Get.self, Stop.self])
    @OptionGroup var options: CommonOptions
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start recording the session to a MOV file.")
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @Option(help: "Save to this unused path. Defaults to the configured save folder.") var output: String?
        @MainActor func run() async throws {
            try await options.execute(
                .init(
                    command: "recording.start", session: target.target,
                    arguments: output.map { ["output": .string(absoluteCapturePath($0))] } ?? [:]))
        }
    }
    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the recording's state, file path and elapsed seconds.")
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @MainActor func run() async throws { try await options.execute(.init(command: "recording.get", session: target.target)) }
    }
    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop the recording and finish its file. The result's path is the saved MOV.")
        @OptionGroup var options: CommonOptions
        @OptionGroup var target: SessionOptions
        @MainActor func run() async throws { try await options.execute(.init(command: "recording.stop", session: target.target)) }
    }
}

struct EventsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "events", abstract: "Stream a snapshot, then live session, prompt and recording metadata as NDJSON, until interrupted.")
    @OptionGroup var options: CommonOptions
    @OptionGroup var target: SessionOptions
    @MainActor func run() async throws {
        let client = ControlClient(endpoint: try ControlEndpoint())
        try await ApplicationClient().prepare(client)
        let seconds = try options.timeout.map { try CommandTimeout($0).seconds }
        try await client.events(.init(command: "events", session: target.target, timeout: seconds), timeout: seconds) { event in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try FileHandle.standardOutput.write(contentsOf: encoder.encode(event) + Data([10]))
        }
    }
}

private func absoluteCapturePath(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
}
