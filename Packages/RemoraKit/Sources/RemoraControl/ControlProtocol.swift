import Foundation

/// JSON payloads keep the transport independent of app stores and command adapters.
public enum ControlValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([ControlValue]), object([String: ControlValue])

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([ControlValue].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: ControlValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        }
    }

    public static func encoding(_ value: some Encodable) throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }
}

public struct ControlRequest: Codable, Sendable {
    public let command: String
    public let session: String?
    public let timeout: Double?
    public let arguments: [String: ControlValue]
    /// A display-only label for the program that ran the command line, such as "codex".
    public let agent: String?

    public init(command: String, session: String? = nil, timeout: Double? = nil, arguments: [String: ControlValue] = [:], agent: String? = nil) {
        self.command = command
        self.session = session
        self.timeout = timeout
        self.arguments = arguments
        self.agent = agent
    }

    public init(from decoder: any Decoder) throws {
        let fields = try [String: ControlValue](from: decoder)
        guard Set(fields.keys).isSubset(of: ["command", "session", "timeout", "arguments", "agent"]),
              case .string(let command) = fields["command"], !command.isEmpty else {
            throw ControlFailure(.invalidArgument, "A request needs a command and only known fields.")
        }
        self.command = command
        switch fields["timeout"] {
        case nil, .null: timeout = nil
        case .number(let seconds) where seconds.isFinite && seconds >= 0 && seconds <= 86_400: timeout = seconds
        default: throw ControlFailure(.invalidArgument, "Invalid command timeout.")
        }
        switch fields["session"] {
        case nil, .null: session = nil
        case .string(let value): session = value
        default: throw ControlFailure(.invalidArgument, "session must be a string.")
        }
        switch fields["arguments"] {
        case nil: arguments = [:]
        case .object(let value): arguments = value
        default: throw ControlFailure(.invalidArgument, "arguments must be an object.")
        }
        switch fields["agent"] {
        case nil, .null: agent = nil
        case .string(let value): agent = value.isEmpty ? nil : String(value.prefix(64))
        default: throw ControlFailure(.invalidArgument, "agent must be a string.")
        }
    }
}

public struct ControlFailure: Error, Codable, Sendable, Equatable, LocalizedError {
    public enum Code: String, Codable, Sendable, CaseIterable {
        case captureFailed = "capture-failed", noFrame = "no-frame", recordingBusy = "recording-busy"
        case `internal`, ioFailed = "io-failed", outcomeUnknown = "outcome-unknown"
        case invalidArgument = "invalid-argument", unknownCommand = "unknown-command"
        case appUnavailable = "app-unavailable", notFound = "not-found", ambiguousTarget = "ambiguous-target"
        case unsupported, sessionRequired = "session-required", sessionEnded = "session-ended"
        case notConnected = "not-connected", promptRequired = "prompt-required", userActive = "user-active"
        case agentStopped = "agent-stopped"
        case inputBusy = "input-busy", observationRequired = "observation-required"
        case backendFailed = "backend-failed", connectionDeleted = "connection-deleted", sessionExists = "session-exists"
        case storeFailed = "store-failed", credentialFailed = "credential-failed", promptResolved = "prompt-resolved"
        case destinationExists = "destination-exists", frameTimeout = "frame-timeout"
        case streamOverflow = "stream-overflow", imageExpired = "image-expired"
        case timeout, cancelled

        public var exitCode: Int32 {
            switch self {
            case .internal, .captureFailed, .ioFailed, .outcomeUnknown, .storeFailed, .credentialFailed, .backendFailed: 1
            case .invalidArgument, .unknownCommand: 2
            case .appUnavailable, .notFound, .ambiguousTarget, .unsupported, .sessionRequired, .sessionEnded, .promptResolved, .connectionDeleted, .streamOverflow, .imageExpired: 3
            case .notConnected, .promptRequired, .userActive, .agentStopped, .inputBusy, .observationRequired, .sessionExists, .noFrame, .recordingBusy, .destinationExists: 4
            case .timeout, .frameTimeout: 5
            case .cancelled: 130
            }
        }
    }

    public let code: Code
    public let message: String
    public let hint: String
    public let details: ControlValue?
    public var errorDescription: String? { message }

    public init(_ code: Code, _ message: String, hint: String = "", details: ControlValue? = nil) {
        self.details = details
        self.code = code
        self.message = message
        self.hint = hint
    }
}

public enum ControlResponse: Codable, Sendable, Equatable {
    case success(ControlValue)
    case failure(ControlFailure)

    private enum CodingKeys: String, CodingKey { case ok, result, error }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        if try fields.decode(Bool.self, forKey: .ok) {
            self = .success(try fields.decode(ControlValue.self, forKey: .result))
        } else {
            self = .failure(try fields.decode(ControlFailure.self, forKey: .error))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .success(let value):
            try fields.encode(true, forKey: .ok)
            try fields.encode(value, forKey: .result)
        case .failure(let value):
            try fields.encode(false, forKey: .ok)
            try fields.encode(value, forKey: .error)
        }
    }
}

public struct ControlEvent: Codable, Sendable {
    public let type: String
    public let cursor: String
    public let data: ControlValue

    public init(type: String, cursor: String, data: ControlValue) {
        self.type = type
        self.cursor = cursor
        self.data = data
    }
}

public struct AppStatus: Codable, Sendable {
    public let running: Bool
    public let pid: Int32?
    public let hidden: Bool
    public let windowVisible: Bool
    public let settingsVisible: Bool
    public let sessions: Int

    public init(running: Bool, pid: Int32? = nil, hidden: Bool = false,
                windowVisible: Bool = false, settingsVisible: Bool = false, sessions: Int = 0) {
        self.running = running
        self.pid = pid
        self.hidden = hidden
        self.windowVisible = windowVisible
        self.settingsVisible = settingsVisible
        self.sessions = sessions
    }
}

public struct CommandTimeout: Sendable, Equatable {
    public let seconds: Double

    public init(_ text: String) throws {
        let multiplier: Double
        let digits: Substring
        if text.hasSuffix("ms") { multiplier = 0.001; digits = text.dropLast(2) }
        else if text.hasSuffix("s") { multiplier = 1; digits = text.dropLast() }
        else if text.hasSuffix("m") { multiplier = 60; digits = text.dropLast() }
        else { multiplier = 1; digits = text[...] }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let number = Double(digits), number.isFinite, number >= 0,
              (number * multiplier).isFinite, number * multiplier <= 86_400 else {
            throw ControlFailure(.invalidArgument, "Invalid timeout '\(text)'.", hint: "Use seconds, ms, s or m, from 0 to 24h.")
        }
        seconds = number * multiplier
    }
}
