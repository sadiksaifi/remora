import Foundation

public struct ControlResolution: Sendable, Equatable {
    public let width: Int?
    public let height: Int?

    public init(_ text: String, allowFit: Bool = true) throws {
        if allowFit && text == "fit" {
            width = nil
            height = nil
            return
        }
        let parts = text.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
            (200...8192).contains(width), (200...8192).contains(height), width.isMultiple(of: 2)
        else {
            throw ControlFailure(.invalidArgument, "Resolution must be fit or WIDTHxHEIGHT, 200 to 8192 pixels per side with an even width.")
        }
        self.width = width
        self.height = height
    }
}

public enum PasswordInput {
    /// Password input removes one line ending and preserves every other character.
    public static func decode(_ data: Data) throws -> String {
        guard var text = String(data: data, encoding: .utf8), !text.utf8.contains(0) else {
            throw ControlFailure(.invalidArgument, "Password stdin must be UTF-8 without NUL bytes.")
        }
        if text.hasSuffix("\r\n") { text.removeLast() } else if text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}

extension ControlRequest {
    public func validateArguments(_ allowed: Set<String>, sessionAllowed: Bool = false) throws {
        guard sessionAllowed || session == nil, Set(arguments.keys).isSubset(of: allowed) else {
            throw ControlFailure(.invalidArgument, "The command received unknown arguments.")
        }
    }

    public func string(_ key: String, required: Bool = false) throws -> String? {
        guard let value = arguments[key] else {
            if required { throw ControlFailure(.invalidArgument, "Missing \(key).") }
            return nil
        }
        guard case .string(let text) = value else { throw ControlFailure(.invalidArgument, "\(key) must be a string.") }
        return text
    }

    public func flag(_ key: String) throws -> Bool {
        guard let value = arguments[key] else { return false }
        guard case .bool(let flag) = value else { throw ControlFailure(.invalidArgument, "\(key) must be a boolean.") }
        return flag
    }
}
