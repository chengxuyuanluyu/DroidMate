import Foundation
import UserNotifications
import os

private let log = Logger(subsystem: "com.droidmate", category: "NotificationBridge")

/// Receives Android notification mirror pushes from the server and surfaces
/// them via `UNUserNotificationCenter` (only when running as a real .app —
/// `swift run` is skipped because UNUserNotificationCenter requires a bundle).
///
/// See docs/PROTOCOL.md §8. Single-direction (Android → Mac); no echo.
@MainActor
final class NotificationBridge: ObservableObject {

    /// Defaults to OFF — notifications are sensitive (may contain 2FA codes,
    /// private messages). Users opt in via Settings.
    private var mirrorEnabled: Bool {
        UserDefaults.standard.object(forKey: "notifications.mirror_android") as? Bool ?? false
    }

    /// Suppressed categories: incoming calls/alarms would create an annoying
    /// double-prompt (Android already ringing + Mac banner).
    private let suppressedCategories: Set<String> = ["call", "alarm"]

    /// Tracks shown (key, title, text) so we don't trigger UN de-dup.
    /// Server already de-dups by (key, title, text), but its dedup depends on
    /// dumpsys parsing which is unstable across Android versions/ROMs — same
    /// sbn key can yield different parsed title/text between polls, causing
    /// server to re-send what it thinks is an update. This is the client's
    /// last line of defense against duplicate banners.
    /// Array (not Set) so we keep insertion order — `removeFirst` drops the
    /// oldest signature when the cap is hit, which is the intended LRU-ish trim.
    private var shownSignatures: [String] = []
    private let maxSignatures = 200

    func bind(transport: TransportClient) {
        transport.setNotificationsHandler { [weak self] frame in
            await self?.handle(frame)
        }
        log.info("bound to transport, mirrorEnabled=\(self.mirrorEnabled)")
    }

    private func handle(_ frame: Frame) async {
        guard mirrorEnabled else { return }
        guard Bundle.main.bundleIdentifier != nil else {
            log.warning("skip: no bundle id (swift run mode) — UNUserNotificationCenter unavailable")
            return
        }

        switch frame.msgType {
        case MsgType.notificationAdded:
            guard let payload = try? WireJSON.decoder.decode(
                NotificationAddedPayload.self, from: frame.payload
            ) else {
                log.warning("decode failed: NOTIFICATION_ADDED len=\(frame.payload.count)")
                return
            }
            log.info("← added notification (payload bytes=\(frame.payload.count))")
            await show(payload)
        case MsgType.notificationRemoved:
            log.debug("removed notification (payload bytes=\(frame.payload.count); macOS can't dismiss)")
        default:
            log.warning("unknown notif msg=0x\(frame.msgType, format: .hex)")
        }
    }

    private func show(_ n: NotificationAddedPayload) async {
        if let cat = n.category, suppressedCategories.contains(cat) {
            log.debug("suppressed mirrored notification category")
            return
        }

        let sig = "\(n.key)|\(n.title)|\(n.text)"
        if shownSignatures.contains(sig) {
            log.debug("dedup sig, skip")
            return
        }
        shownSignatures.append(sig)
        if shownSignatures.count > maxSignatures {
            shownSignatures.removeFirst(shownSignatures.count - maxSignatures)
        }

        let content = UNMutableNotificationContent()
        // Prefer cached application label when App Manager has resolved it.
        let label = AdbAppManager.shared.labelForPackage(n.package) ?? simplifyPackage(n.package)
        content.title = label
        content.subtitle = n.title
        content.body = n.text
        content.sound = .default
        content.categoryIdentifier = TransferNotificationCenter.androidMirrorCategoryId
        content.userInfo = [
            TransferNotificationCenter.androidPackageKey: n.package,
            TransferNotificationCenter.kindKey: TransferNotificationCenter.kindAndroidMirror,
        ]

        let request = UNNotificationRequest(
            identifier: "droidmate.\(n.key)",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            log.info("displayed mirrored notification")
        } catch {
            log.error("UN add failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// com.example.app → "Example". com.facebook.katana → "Facebook".
    /// Heuristic; not always right but acceptable for a banner title.
    private func simplifyPackage(_ pkg: String) -> String {
        let last = pkg.split(separator: ".").last ?? Substring(pkg)
        return last.prefix(1).uppercased() + last.dropFirst()
    }
}
