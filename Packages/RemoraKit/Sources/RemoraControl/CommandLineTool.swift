import Foundation

/// A link Remora owns: the `remora` command on the user's PATH, or the `remora` folder in an agent's skills folder.
/// Remora Dev's links are named `remora-dev`.
/// Remora creates, updates and removes only its own links. It replaces another app's or tool's link only when the user confirms,
/// and it never replaces a file or folder that isn't a link.
public struct CommandLineTool: Sendable {
    public enum State: String, Sendable {
        case notInstalled
        /// The link points to this copy of the app.
        case installed
        /// The link points to another copy of this app, decided by its bundle identifier.
        case otherCopy
        /// The link points into an app that was moved or deleted, or into a copy of this app that lacks the file.
        /// The link has this app's name, so a moved or renamed copy made it.
        case broken
        /// The link points to another app or tool. Replacing it takes the user's confirmation.
        case otherLink
        /// A file or folder that isn't a link is at the link's path.
        case conflict

        /// The status line that Settings and the CLI show.
        public var summary: String {
            let name = AppIdentity.current.name
            return switch self {
            case .notInstalled: "Not installed"
            case .installed: "Installed"
            case .otherCopy: "Points to another copy of \(name)"
            case .broken: "\(name) was moved or deleted"
            case .otherLink: "Points to another app or tool"
            case .conflict: "Another file is in the way"
            }
        }
    }

    public enum Failure: Error, LocalizedError {
        case conflict(String)
        /// The link at the first path points to the second.
        case otherLink(String, String)
        case notInstalled
        /// The app runs from a disk image or from App Translocation's temporary copy, so a link to it would soon break.
        case readOnlyApp

        public var errorDescription: String? {
            switch self {
            case .conflict(let path): "Another file or folder is already at \(path). Move or rename it, then come back to install."
            case .otherLink(let path, let destination): "The link at \(path) points to \(destination), which belongs to another app or tool."
            case .notInstalled: "The command-line tool is not installed."
            case .readOnlyApp: "\(AppIdentity.current.name) is running from a disk image or a temporary location, so a link to it would stop working."
            }
        }

        public var recoverySuggestion: String? {
            guard case .readOnlyApp = self else { return nil }
            return "Move \(AppIdentity.current.name) to the Applications folder, open it from there, then install again."
        }
    }

    public static let pathAdvice = "Make sure ~/.local/bin is on your PATH."
    public static let pathCommand = #"export PATH="$HOME/.local/bin:$PATH""#

    public let link: URL
    public let target: URL

    /// `target` is the file the link points to, by default this app's bundled executable, `Remora.app/Contents/Helpers/remora`.
    public init(
        target: URL = AppIdentity.current.app.appending(path: "Contents/Helpers/remora"),
        link: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/\(AppIdentity.current.commandName)")
    ) {
        self.target = target
        self.link = link
    }

    /// The link's path for display, such as ~/.local/bin/remora.
    public var displayPath: String { (link.path as NSString).abbreviatingWithTildeInPath }

    /// Where the link points, resolved as the file system resolves it, or nil when nothing or a file that isn't a symbolic link is at its path.
    var destination: URL? {
        guard let path = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return nil }
        return Self.resolved(path.hasPrefix("/") ? path : link.deletingLastPathComponent().path + "/" + path)
    }

    /// `path` with its deepest existing ancestor resolved by `realpath`, so `..` after a linked folder leaves the folder the link points to.
    /// Collapsing `..` first, as URLs do, would read a different folder.
    static func resolved(_ path: String) -> URL {
        var (head, tail) = (path, [String]())
        while true {
            if let real = realpath(head, nil) {
                defer { free(real) }
                return URL(fileURLWithPath: NSString.path(withComponents: [String(cString: real)] + tail)).standardizedFileURL
            }
            tail.insert((head as NSString).lastPathComponent, at: 0)
            head = (head as NSString).deletingLastPathComponent
        }
    }

    /// Where the link points, for display, or an empty string when it isn't a symbolic link.
    public var displayDestination: String { destination.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "" }

    /// The app the link points into, when it points to the same file inside an app as the target, such as `Other.app` for
    /// `Other.app/Contents/Helpers/remora`.
    var linkedApp: URL? {
        guard let destination, let app = Self.app(containing: target) else { return nil }
        let inside = Array(target.standardizedFileURL.pathComponents.dropFirst(app.pathComponents.count))
        let components = destination.pathComponents
        guard components.count > inside.count, Array(components.suffix(inside.count)) == inside else { return nil }
        let linked = URL(fileURLWithPath: NSString.path(withComponents: Array(components.dropLast(inside.count))))
        return linked.pathExtension == "app" ? linked : nil
    }

    public var state: State {
        let manager = FileManager.default
        guard (try? manager.attributesOfItem(atPath: link.path)) != nil else { return .notInstalled }
        guard let destination else { return .conflict }
        let exists = manager.fileExists(atPath: destination.path)
        if destination == Self.resolved(target.path) { return exists ? .installed : .broken }
        // A missing app was moved or deleted. An app that is still there belongs to this variant only with its bundle identifier.
        guard let linkedApp else { return .otherLink }
        guard manager.fileExists(atPath: linkedApp.path) else { return .broken }
        func bundleIdentifier(_ app: URL?) -> String? { app.flatMap { Bundle(url: $0)?.bundleIdentifier } }
        let identifier = bundleIdentifier(linkedApp)
        guard identifier != nil, identifier == bundleIdentifier(Self.app(containing: target)) else { return .otherLink }
        return exists ? .otherCopy : .broken
    }

    /// Points the link at this copy of the app, and creates it if it's missing. It replaces another app's or tool's link only with
    /// `replacingOtherLink`, and never replaces a file or folder that isn't a link.
    public func install(replacingOtherLink: Bool = false) throws {
        try requireWritableTarget()
        switch state {
        case .installed: return
        case .notInstalled: try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        case .otherLink where !replacingOtherLink: throw otherLinkFailure
        case .conflict: throw Failure.conflict(displayPath)
        case .otherCopy, .broken, .otherLink: try FileManager.default.removeItem(at: link)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    }

    /// Removes this app's link, including one to another copy of this app or a broken one.
    public func uninstall() throws {
        switch state {
        case .notInstalled: throw Failure.notInstalled
        case .otherLink: throw otherLinkFailure
        case .conflict: throw Failure.conflict(displayPath)
        case .installed, .otherCopy, .broken: try FileManager.default.removeItem(at: link)
        }
    }

    private var otherLinkFailure: Failure { .otherLink(displayPath, displayDestination) }

    /// Whether a new Terminal shell runs `remora` from this link, or nil when the shell fails, takes over 3 seconds or never prints an answer.
    /// A GUI app's PATH lacks what shell config adds, so this asks the user's login shell in a clean environment.
    public func isOnShellPath() async -> Bool? {
        let shell = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        // Record separators mark the answer, because shell config can print escapes on the same line.
        process.arguments = ["-l", "-i", "-c", #"printf '\036%s\036' "$(command -v "# + link.lastPathComponent + #")""#]
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "USER": NSUserName(), "SHELL": shell, "TERM": "dumb"]
        (process.standardInput, process.standardOutput, process.standardError) = (FileHandle.nullDevice, output, FileHandle.nullDevice)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                guard (try? process.run()) != nil else { return continuation.resume(returning: nil) }
                // An interactive shell ignores SIGTERM.
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let answer = Self.shellAnswer(in: String(decoding: data, as: UTF8.self))
                let answered = process.terminationReason == .exit && [0, 1].contains(process.terminationStatus)
                // Compare resolved paths, because a dotfiles setup can link ~/.local or put another link to this helper first.
                let runsHelper = answer.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() == link.resolvingSymlinksInPath() }
                continuation.resume(returning: answered ? runsHelper : nil)
            }
        }
    }

    /// The text between the last pair of record separators, or nil when the shell never printed the answer.
    static func shellAnswer(in output: String) -> String? {
        let parts = output.components(separatedBy: "\u{1E}")
        return parts.count >= 3 ? parts[parts.count - 2] : nil
    }

    /// Gatekeeper's App Translocation and a mounted disk image both serve the app from a read-only volume.
    private func requireWritableTarget() throws {
        if (try? target.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true { throw Failure.readOnlyApp }
    }

    /// The innermost app bundle in `url`'s path.
    private static func app(containing url: URL) -> URL? {
        var app = url.standardizedFileURL
        while app.pathComponents.count > 1 {
            if app.pathExtension == "app" { return app }
            app.deleteLastPathComponent()
        }
        return nil
    }
}
