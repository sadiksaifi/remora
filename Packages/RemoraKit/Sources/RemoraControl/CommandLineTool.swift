import Foundation

/// The `remora` link on the user's PATH. Remora creates, replaces and removes only links to a Remora helper,
/// so it never overwrites or deletes a file it didn't create.
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
    public let helper: URL

    /// `helper` is the bundled executable, `Remora.app/Contents/Helpers/remora`.
    public init(helper: URL, link: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/remora")) {
        self.helper = helper
        self.link = link
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
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: helper)
        case .conflict: throw Failure.conflict(displayPath)
        case .installed, .broken: try repair()
        }
    }

    /// Points Remora's link at this copy of Remora.
    public func repair() throws {
        try uninstall()
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: helper)
    }

    public func uninstall() throws {
        switch state {
        case .notInstalled: throw Failure.notInstalled
        case .conflict: throw Failure.conflict(displayPath)
        case .installed, .broken: try FileManager.default.removeItem(at: link)
        }
    }

    /// A symbolic link to a Remora helper, here or in a moved or deleted copy of Remora.
    private var isOwned: Bool {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return false }
        let target = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent()).standardizedFileURL
        return target == helper.standardizedFileURL || target.path.hasSuffix("/Remora.app/Contents/Helpers/remora")
    }
}
