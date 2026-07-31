import SwiftUI

/// First-launch welcome flow. Shown once until the user finishes or skips;
/// can be reopened from Settings → About.
struct OnboardingView: View {
    let onFinished: () -> Void

    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pages: [Page] = [
        Page(
            icon: "iphone.gen3.radiowaves.left.and.right",
            title: "Welcome to DroidMate",
            body: "A Finder-native Android file manager for Mac. No app install on your phone — just USB debugging (or wireless adb).",
            bullets: [
                "Browse, download, and upload files",
                "Built-in screen mirror (no extra install)",
                "Optional clipboard & notification sync",
            ]
        ),
        Page(
            icon: "cable.connector",
            title: "Prepare your phone",
            body: "Enable Developer Options, then turn on USB debugging. Unlock the phone and accept the RSA prompt when you plug in.",
            bullets: [
                "Settings → About phone → tap Build number 7×",
                "Developer Options → USB debugging ON",
                "Xiaomi/HyperOS: also enable 「USB调试（安全设置）」for mirror control",
            ]
        ),
        Page(
            icon: "link",
            title: "Connect",
            body: "Plug in with a cable for the simplest path. DroidMate auto-connects when a device appears. Prefer wireless? Use Wi-Fi pairing or “switch to Wi-Fi” after USB.",
            bullets: [
                "USB: plug in → accept prompt → wait for auto-connect",
                "Wi-Fi: pair once, then reconnect from Recent",
                "Already on USB? One tap switches the session to Wi-Fi",
            ]
        ),
        Page(
            icon: "sparkles",
            title: "Everyday tips",
            body: "Once connected you get a familiar file browser — plus a floating bar when you mirror.",
            bullets: [
                "⌘S download · ⌥⌘S choose folder · drag files to upload",
                "Toolbar airplay → Start Mirror, or Start Mirror & Record",
                "⌘F search · ★ pin folders · ⌘K command palette",
            ]
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
            HStack(spacing: 8) {
                ForEach(0..<pages.count, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: i == page ? 20 : 8, height: 6)
                        .animation(reduceMotion ? nil : AppSpring.snappy, value: page)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 8)

            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, p in
                    pageContent(p)
                        .tag(index)
                }
            }
            // macOS 15+: page style where available; fall back to plain content switch.
            .tabViewStyle(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if page < pages.count - 1 {
                    Button("Skip") { onFinished() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .keyboardShortcut(.cancelAction)
                }

                Spacer()

                if page > 0 {
                    Button("Back") {
                        withAnimation(AppSpring.standard) { page -= 1 }
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                }

                if page < pages.count - 1 {
                    Button("Continue") {
                        withAnimation(AppSpring.standard) { page += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .keyboardShortcut(.rightArrow, modifiers: [])
                } else {
                    Button("Get Started") { onFinished() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func pageContent(_ p: Page) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 8)
            BrandMark(size: 72, systemImage: p.icon)

            Text(p.title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(p.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: DM.Space.sm + 2) {
                ForEach(Array(p.bullets.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(DM.Brand.iconOnDark)
                            .font(.body)
                        Text(line)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(DM.Space.lg)
            .frame(maxWidth: 440, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DM.Radius.lg, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DM.Radius.lg, style: .continuous)
                    .strokeBorder(DM.cardStroke, lineWidth: 0.5)
            )

            Spacer(minLength: 8)
        }
        .padding(.horizontal, DM.Space.xxl)
        .padding(.vertical, DM.Space.md)
    }

    private struct Page {
        let icon: String
        let title: LocalizedStringKey
        let body: LocalizedStringKey
        let bullets: [LocalizedStringKey]
    }
}
