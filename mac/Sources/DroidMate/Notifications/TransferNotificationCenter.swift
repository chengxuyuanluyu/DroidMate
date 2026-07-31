import AppKit
import Foundation
import UserNotifications

/// UNUserNotificationCenter delegate for transfer + Android mirror notifications.
@MainActor
final class TransferNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TransferNotificationCenter()

    /// Stable string keys — safe from any isolation domain.
    nonisolated static let categoryId = "droidmate.transfer.done"
    nonisolated static let showInFinderAction = "show_in_finder"
    nonisolated static let pathKey = "destinationPath"

    nonisolated static let androidMirrorCategoryId = "droidmate.android.mirror"
    nonisolated static let openAppAction = "open_android_app"
    nonisolated static let androidPackageKey = "androidPackage"
    nonisolated static let kindKey = "kind"
    nonisolated static let kindAndroidMirror = "android_mirror"

    /// Serial of the active Device Session (set from the app root).
    var activeSerialProvider: (() -> String?)?

    private var didSetup = false

    func setup() {
        guard !didSetup else { return }
        didSetup = true
        guard Bundle.main.bundleIdentifier != nil else { return }

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let show = UNNotificationAction(
            identifier: Self.showInFinderAction,
            title: String(localized: "Show in Finder"),
            options: [.foreground]
        )
        let transferCategory = UNNotificationCategory(
            identifier: Self.categoryId,
            actions: [show],
            intentIdentifiers: [],
            options: []
        )

        let openApp = UNNotificationAction(
            identifier: Self.openAppAction,
            title: String(localized: "Open on Phone"),
            options: [.foreground]
        )
        let mirrorCategory = UNNotificationCategory(
            identifier: Self.androidMirrorCategoryId,
            actions: [openApp],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([transferCategory, mirrorCategory])
    }

    // Show banner even when DroidMate is focused.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let kind = info[Self.kindKey] as? String
        let path = info[Self.pathKey] as? String
        let pkg = info[Self.androidPackageKey] as? String
        let action = response.actionIdentifier

        await MainActor.run {
            if kind == Self.kindAndroidMirror, let pkg {
                // Default tap or explicit "Open on Phone".
                if action == Self.openAppAction
                    || action == UNNotificationDefaultActionIdentifier {
                    Self.openAndroidPackage(pkg, serial: self.activeSerialProvider?())
                }
                return
            }
            if action == Self.showInFinderAction
                || action == UNNotificationDefaultActionIdentifier {
                Self.revealInFinder(path: path)
            }
        }
    }

    static func revealInFinder(path: String?) {
        guard let path, !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if let parent = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            NSWorkspace.shared.open(parent)
        }
    }

    static func openAndroidPackage(_ package: String, serial: String?) {
        guard let serial, !serial.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            try? AdbAppManager.shared.launchPackage(serial: serial, package: package)
        }
    }
}
