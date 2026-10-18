import Foundation

/// A link Remora owns: the `remora` command on the user's PATH, or the `remora` folder in an agent's skills folder.
/// Remora creates, replaces and removes only its own links, so it never overwrites or deletes a file it didn't create.
public struct CommandLineTool: Sendable {
    public enum State: String, Sendable {
        case notInstalled, installed
        /// Remora's link points to a helper that was moved or deleted.
        case broken
        /// Another file is at the link's path.
        case conflict
    }

    public enum Failure: Error, LocalizedError {
        case conflict(String), notInstalled

        public var errorDescription: String? {
            switch self {
            case .conflict(let path): "Another file is already at \(path). Move or rename it, then come back to install."
            case .notInstalled: "The command-line tool is not installed."
            }
        }
    }

    public static let pathAdvice = "Make sure ~/.local/bin is on your PATH."
    public static let pathCommand = #"export PATH="$HOME/.local/bin:$PATH""#

    public let link: URL
    public let target: URL
    private let adoptsOtherCopies: Bool

    /// `target` is the file the link points to, such as the bundled executable, `Remora.app/Contents/Helpers/remora`.
    /// With `adoptsOtherCopies`, a link to a Remora helper in another copy of Remora also counts as Remora's.
    public init(target: URL, link: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/remora"),
                adoptsOtherCopies: Bool = true) {
        self.target = target
        self.link = link
        self.adoptsOtherCopies = adoptsOtherCopies
    }

    /// The link's path for display, such as ~/.local/bin/remora.
    public var displayPath: String { (link.path as NSString).abbreviatingWithTildeInPath }

    public var state: State {
        let manager = FileManager.default
        guard (try? manager.attributesOfItem(atPath: link.path)) != nil else { return .notInstalled }
        guard isOwned else { return .conflict }
        return manager.fileExists(atPath: link.path) ? .installed : .broken
    }

    /// Creates the link. It fails rather than replace anything already at the path.
    public func install() throws {
        switch state {
        case .notInstalled:
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        case .conflict: throw Failure.conflict(displayPath)
        case .installed, .broken: try repair()
        }
    }

    /// Points Remora's link at this copy of Remora.
    public func repair() throws {
        try uninstall()
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    }

    public func uninstall() throws {
        switch state {
        case .notInstalled: throw Failure.notInstalled
        case .conflict: throw Failure.conflict(displayPath)
        case .installed, .broken: try FileManager.default.removeItem(at: link)
        }
    }

    /// Whether a new Terminal shell runs `remora` from this link, or nil when the shell fails or takes over 3 seconds.
    /// A GUI app's PATH lacks what shell config adds, so this asks the user's login shell in a clean environment.
    public func isOnShellPath() async -> Bool? {
        let shell = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "command -v remora"]
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "USER": NSUserName(), "SHELL": shell, "TERM": "dumb"]
        (process.standardInput, process.standardOutput, process.standardError) = (FileHandle.nullDevice, output, FileHandle.nullDevice)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                guard (try? process.run()) != nil else { return continuation.resume(returning: nil) }
                // An interactive shell ignores SIGTERM.
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                // Shell config may print other output, such as terminal escapes, before the answer.
                let found = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init)
                let answered = process.terminationReason == .exit && [0, 1].contains(process.terminationStatus)
                continuation.resume(returning: answered ? found == link.path : nil)
            }
        }
    }

    /// A symbolic link to the target, or with `adoptsOtherCopies` to a Remora helper in a moved or deleted copy of Remora.
    private var isOwned: Bool {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return false }
        let found = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent()).standardizedFileURL
        return found == target.standardizedFileURL
            || adoptsOtherCopies && found.path.hasSuffix("/Remora.app/Contents/Helpers/remora")
    }
}
