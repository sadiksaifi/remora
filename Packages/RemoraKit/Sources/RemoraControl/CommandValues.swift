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

public enum StandardInput {
    /// Reads a descriptor to end of file, fails at the 1 MiB request size limit, and ends at the deadline or when the task is cancelled.
    /// It reads only after poll reports an event, so it never blocks or leaves a read running. `FileHandle.readabilityHandler` never reports a regular file's end.
    /// poll reports devices such as /dev/null as invalid, so read decides. A nonblocking descriptor without data waits, and its flags stay unchanged.
    public static func read(_ descriptor: Int32 = STDIN_FILENO, until deadline: ContinuousClock.Instant) async throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            if poll(&event, 1, 0) > 0 {
                let (count, error) = buffer.withUnsafeMutableBytes { (Darwin.read(descriptor, $0.baseAddress, $0.count), errno) }
                if count == 0 { return data }
                if count > 0 {
                    data.append(contentsOf: buffer[..<count])
                    guard data.count < 1_048_576 else { throw ControlFailure(.invalidArgument, "Stdin exceeds the request size limit.") }
                    continue
                }
                guard error == EAGAIN || error == EINTR else { throw ControlFailure(.ioFailed, "Could not read stdin.") }
            }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw ControlFailure(
                    .timeout, "Stdin did not reach end of file before the deadline.",
                    hint: "Close stdin after writing the input, or pass a longer --timeout. Nothing was sent.")
            }
            do { try await Task.sleep(for: min(remaining, .milliseconds(10))) } catch { throw ControlFailure(.cancelled, "The command was interrupted.") }
        }
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
