import ArgumentParser
import Foundation
import RemoraControl

struct ImageOptions: ParsableArguments {
    @Option(help: "Map pointer coordinates from this screenshot receipt.") var image: String?
    func adding(to arguments: [String: ControlValue]) -> [String: ControlValue] {
        var arguments = arguments
        if let image { arguments["image"] = .string(image) }
        return arguments
    }
}

struct MoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "move", abstract: "Move the remote pointer in top-left pixels.")
    @OptionGroup var options: CommonOptions
    @OptionGroup var target: SessionOptions
    @OptionGroup var basis: ImageOptions
    @Argument var x: Int
    @Argument var y: Int
    @MainActor func run() async throws {
        try await options.execute(.init(command: "move", session: target.target,
            arguments: basis.adding(to: ["x": .number(Double(x)), "y": .number(Double(y))])))
    }
}

struct ClickCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "click", abstract: "Click a remote point. Counts acknowledge protocol submission.")
    @OptionGroup var options: CommonOptions
    @OptionGroup var target: SessionOptions
    @OptionGroup var basis: ImageOptions
    @Argument var x: Int
    @Argument var y: Int
    @Option var button = "left"
    @Option var count = 1
    @Option var modifiers: String?
    @MainActor func run() async throws {
        var args: [String: ControlValue] = ["x": .number(Double(x)), "y": .number(Double(y)), "button": .string(button), "count": .number(Double(count))]
        if let modifiers { args["modifiers"] = .string(modifiers) }
        try await options.execute(.init(command: "click", session: target.target, arguments: basis.adding(to: args)))
    }
}

struct DragCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "drag", abstract: "Drag between remote points.")
    @OptionGroup var options: CommonOptions
    @OptionGroup var target: SessionOptions
    @OptionGroup var basis: ImageOptions
    @Option var from: String
    @Option var to: String
    @Option var button = "left"
    @Option var modifiers: String?
    @Option var duration = "500ms"
    @MainActor func run() async throws {
        var args: [String: ControlValue] = ["from": try inputPoint(from), "to": try inputPoint(to), "button": .string(button),
            "durationMs": .number(try CommandTimeout(duration).seconds * 1000)]
        if let modifiers { args["modifiers"] = .string(modifiers) }
        try await options.execute(.init(command: "drag", session: target.target, arguments: basis.adding(to: args)), defaultTimeout: "60s")
    }
}

struct ScrollCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "scroll", abstract: "Scroll signed notches at a remote point. Positive is right/down.")
    @OptionGroup var options: CommonOptions
    @OptionGroup var target: SessionOptions
    @OptionGroup var basis: ImageOptions
    @Option var at: String
    @Option(parsing: .unconditional) var dx: Double = 0
    @Option(parsing: .unconditional) var dy: Double = 0
    @MainActor func run() async throws {
        try await options.execute(.init(command: "scroll", session: target.target, arguments: basis.adding(to:
            ["at": try inputPoint(at), "dx": .number(dx), "dy": .number(dy)])))
    }
}

struct TypeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "type", abstract: "Send Unicode text without using the clipboard or Mac keyboard.")
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
                throw ControlFailure(.invalidArgument, "Text stdin must be UTF-8.")
            }
            value = decoded
        }
        try await options.execute(.init(command: "type", session: target.target, arguments: ["text": .string(value)]), defaultTimeout: "60s")
    }
}

struct KeyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "key", abstract: "Press a physical key chord, such as Ctrl+Alt+Delete or Win+R.")
    @OptionGroup var options: CommonOptions
    @OptionGroup var target: SessionOptions
    @Argument var chord: String
    @Option(name: .customLong("repeat")) var repetitions = 1
    @MainActor func run() async throws {
        try await options.execute(.init(command: "key", session: target.target,
            arguments: ["key": .string(chord), "repeat": .number(Double(repetitions))]))
    }
}

struct InputCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "input", abstract: "Run up to 256 ordered JSON actions within 60 seconds.", discussion: """
        Stdin holds a JSON array, such as [{"action":"click","x":100,"y":200}]. Points are pixels from the top-left, or [x,y] pairs for from, to and at.

        ACTION       FIELDS
        move         x, y
        click        x, y, button, count 1-3, modifiers
        drag         from, to, button, modifiers, durationMs 1-10000 (default 500)
        scroll       at, dx, dy (notches, positive is right or down)
        type         text
        key          key (a chord), repeat 1-100
        delay        durationMs 0-60000
        key-down     key (one physical key)
        key-up       key
        button-down  x, y, button
        button-up    x, y, button

        Buttons are left, right, middle, back and forward. key-up and button-up need a matching down earlier in the batch. Anything still held is released when the batch ends.
        """)
    @OptionGroup var options: CommonOptions
    @OptionGroup var target: SessionOptions
    @OptionGroup var basis: ImageOptions
    @Flag(name: .customLong("stdin"), help: "Read the JSON action array from stdin. Required.") var readStdin = false
    @MainActor func run() async throws {
        guard readStdin else { throw ControlFailure(.invalidArgument, "Use input --stdin with a JSON action array.") }
        let actions: ControlValue
        do { actions = try JSONDecoder().decode(ControlValue.self, from: try await readStandardInput()) }
        catch let failure as ControlFailure { throw failure }
        catch { throw ControlFailure(.invalidArgument, "Stdin must contain a JSON action array.") }
        try await options.execute(.init(command: "input", session: target.target, arguments: basis.adding(to: ["actions": actions])), defaultTimeout: "60s")
    }
}

private func inputPoint(_ text: String) throws -> ControlValue {
    let parts = text.split(separator: ",", omittingEmptySubsequences: false)
    guard parts.count == 2, let x = Int(parts[0]), let y = Int(parts[1]) else {
        throw ControlFailure(.invalidArgument, "A point requires X,Y integers.")
    }
    return .array([.number(Double(x)), .number(Double(y))])
}
