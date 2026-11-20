import AppKit
import Sparkle
import os

/// Checks for, downloads and installs updates with Sparkle's standard user interface.
/// Only a build that names an update feed and its signing key in its Info.plist has updates. Remora names both.
/// Remora Dev names no feed, so it never checks for updates or replaces itself with Remora.
@MainActor
final class AppUpdater {
    /// Sparkle's user defaults for the choices its first prompt offers. Sparkle observes them, so Settings binds to them directly.
    static let automaticChecksKey = "SUEnableAutomaticChecks"
    static let automaticDownloadsKey = "SUAutomaticallyUpdate"

    private let controller: SPUStandardUpdaterController?

    /// Whether this build checks for and installs updates.
    var isAvailable: Bool { controller != nil }

    init() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        if feed.isEmpty {
            controller = nil
        } else if key.isEmpty {
            Logger(subsystem: "com.peblon.remora", category: "Updates").error(
                "Updates are off: the app names the feed \(feed, privacy: .public) but no SUPublicEDKey to verify updates with.")
            controller = nil
        } else {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
    }

    /// A new Check for Updates… item, or nil when this build has no updates. Sparkle disables it while a check runs.
    func makeMenuItem() -> NSMenuItem? {
        guard let controller else { return nil }
        let item = NSMenuItem(
            title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        item.target = controller
        return item
    }
}
