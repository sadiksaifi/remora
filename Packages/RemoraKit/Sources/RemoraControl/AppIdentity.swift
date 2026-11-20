import Foundation

/// The Remora app this process belongs to: Remora from a Release build, or Remora Dev from a Debug build.
/// The build configuration sets the app's bundle identifier and name. Every value that keeps the two apps' state apart derives from them.
public struct AppIdentity: Sendable {
    /// The app bundle: this app, or the app whose Contents/Helpers holds this command-line tool.
    public let app: URL
    /// com.peblon.remora or com.peblon.remora.dev. It names the Keychain service.
    public let bundleIdentifier: String
    /// Remora or Remora Dev. It names the Application Support folder.
    public let name: String

    public static let current: AppIdentity = {
        // Both Contents/MacOS/<name> and Contents/Helpers/remora sit two folders below the app. The tool often runs through a link.
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundle = Bundle(url: app)
        return AppIdentity(
            app: app, bundleIdentifier: bundle?.bundleIdentifier ?? "",
            name: bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "")
    }()

    /// remora or remora-dev: the name of the command's link, the agent skill and the control socket's folder.
    public var commandName: String { name.lowercased().replacing(" ", with: "-") }

    public var supportDirectory: URL { URL.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory) }
}
