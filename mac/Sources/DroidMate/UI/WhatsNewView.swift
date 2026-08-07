import SwiftUI

/// One-shot release notes sheet. Shown when `CFBundleShortVersionString`
/// differs from the last version the user dismissed.
struct WhatsNewView: View {
    let version: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DM.Space.md) {
                BrandMark(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's New in DroidMate \(version)")
                        .font(.title3.weight(.semibold))
                    Text("Ready for everyday use — mirror, files, and Wi-Fi.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(DM.Space.xl)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DM.Space.md) {
                    bullet(
                        icon: "airplayvideo",
                        title: "Built-in screen mirror",
                        detail: "One-click cast with a branded Dock icon. No separate scrcpy install."
                    )
                    bullet(
                        icon: "record.circle",
                        title: "Two ways to record",
                        detail: "Live clips while mirroring (up to 3 min). Or Start Mirror & Record for longer sessions."
                    )
                    bullet(
                        icon: "slider.horizontal.3",
                        title: "Quality presets",
                        detail: "Smooth / Balanced / High, plus Wi-Fi soft-cap so wireless stays snappy."
                    )
                    bullet(
                        icon: "hand.tap",
                        title: "Xiaomi & HyperOS control",
                        detail: "Clear steps for 「USB调试（安全设置）」so mouse and keys work like stock scrcpy."
                    )
                    bullet(
                        icon: "folder",
                        title: "Finder-class files",
                        detail: "Keep Both, multi-drag, transfers with resume, and a command palette (⌘K)."
                    )
                    bullet(
                        icon: "keyboard",
                        title: "Faster keyboard browsing",
                        detail: "Type-ahead jump, Shift-select, Home/End, and a collapsible inspector (⌥⌘I)."
                    )
                    bullet(
                        icon: "arrow.left.arrow.right.circle",
                        title: "Transfers up front",
                        detail: "Queue from the toolbar or status bar (⌘J). Failures land in Needs Attention for retry."
                    )
                }
                .padding(DM.Space.xl)
            }

            Divider()

            HStack {
                Text("Tip: ⌘K runs mirror, transfers, and disconnect without leaving the keyboard.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Continue") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(DM.Space.lg)
        }
        .frame(minWidth: 440, idealWidth: 500, minHeight: 400, idealHeight: 460)
    }

    private func bullet(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: DM.Space.md) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(DM.Brand.iconOnDark)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

enum AppVersioning {
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// UserDefaults key for the last Whats New version the user dismissed.
    static let lastSeenWhatsNewKey = "ui.last_seen_whats_new_version"
}
