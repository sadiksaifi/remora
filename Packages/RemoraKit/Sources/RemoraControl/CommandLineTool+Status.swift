import Foundation

extension CommandLineTool {
    public var status: ControlValue {
        .object([
            "state": .string(state.rawValue), "path": .string(link.path),
            "target": (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)).map(ControlValue.string) ?? .null,
            "pathAdvice": .string(Self.pathAdvice)
        ])
    }
}
