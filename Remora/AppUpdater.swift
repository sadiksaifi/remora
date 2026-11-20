import AppKit
import Sparkle
import os

/// Checks for, downloads and installs updates with Sparkle's standard user interface.
/// Only a build that names an update feed and its signing key in its Info.plist has updates. Remora names both.
/// Remora Dev names no feed, so it never checks for updates or replaces itself with Remora.
@MainActor
final class AppUpdater: NSObject {
    private var controller: SPUStandardUpdaterController?

    /// Sparkle's updater, whose settings Settings shows, or nil when this build has no updates.
    var sparkle: SPUUpdater? { controller?.updater }

    /// True while a scheduled update waits for the user, in menu-bar-only mode. The menu bar icon shows a mark then.
    private(set) var updateWaiting = false {
        didSet { onUpdateWaitingChange?() }
    }
    var onUpdateWaitingChange: (() -> Void)?

    override init() {
        super.init()
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        if feed.isEmpty { return }
        guard !key.isEmpty else {
            Logger(subsystem: "com.peblon.remora", category: "Updates").error(
                "Updates are off: the app names the feed \(feed, privacy: .public) but no SUPublicEDKey to verify updates with.")
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    /// A new Check for Updates… item, or nil when this build has no updates. It also brings a waiting update's alert forward.
    /// Sparkle disables it while a check runs.
    func makeMenuItem() -> NSMenuItem? {
        guard let controller else { return nil }
        let item = NSMenuItem(
            title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        item.target = controller
        if updateWaiting { item.badge = .updates(count: 1) }
        return item
    }
}

/// Gentle reminders: in menu-bar-only mode, a scheduled update marks the menu bar icon instead of opening an alert
/// behind other apps. Sparkle still shows the alert itself near launch, when the system has been idle, and while a window is open.
extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus || NSApplication.shared.activationPolicy() != .accessory
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { updateWaiting = true }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { updateWaiting = false }

    func standardUserDriverWillFinishUpdateSession() { updateWaiting = false }
}
