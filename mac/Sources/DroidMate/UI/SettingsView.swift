import AppKit
import SwiftUI

/// Grouped settings. Tabs keep the window scannable; each section has a short
/// footer so users know when a toggle takes effect.
struct SettingsView: View {
    @AppStorage(ScrcpyController.qualityPresetKey) private var qualityPresetRaw: String =
        ScrcpyController.QualityPreset.balanced.rawValue
    @AppStorage("mirror.max_size") private var maxSize: Int = 1080
    @AppStorage("mirror.bitrate") private var bitrate: String = "8M"
    @AppStorage("mirror.fps") private var fps: Int = 60
    @AppStorage(ScrcpyController.wirelessOptimizeKey) private var wirelessOptimize: Bool = true
    @AppStorage("audio.enabled") private var audioEnabled: Bool = false
    @AppStorage("mirror.keyboard") private var keyboardMode: String = ScrcpyController.KeyboardMode.sdk.rawValue
    @AppStorage("mirror.mouse") private var mouseMode: String = ScrcpyController.MouseMode.sdk.rawValue
    @AppStorage("mirror.cmd_as_shortcut_mod") private var cmdAsShortcutMod: Bool = true
    @AppStorage("ui.always_on_top") private var alwaysOnTop: Bool = false
    @AppStorage("cache.limit_mb") private var cacheLimitMB: Int = 200
    @AppStorage("clipboard.mac_to_android") private var macToAndroid: Bool = false
    @AppStorage("clipboard.android_to_mac") private var androidToMac: Bool = false
    @AppStorage("notifications.mirror_android") private var mirrorAndroidNotifs: Bool = false
    @AppStorage("transfer.auto_retry") private var autoRetryTransfers: Bool = true
    @AppStorage("transfer.auto_show_queue") private var autoShowTransferQueue: Bool = true
    @AppStorage(DM.AppearancePreference.storageKey) private var appearanceRaw: String =
        DM.AppearancePreference.system.rawValue

    /// Optional shared controller so Mirror tab can show live scrcpy status.
    var scrcpy: ScrcpyController?

    @State private var cacheBytes: Int64 = 0
    @State private var downloadDirPath: String = ""
    @State private var scrcpyAvailable = false
    @State private var scrcpyPathText = ""
    @State private var diagnosticsNote: String?
    /// Suppresses “manual edit → custom” when a preset writes max_size/bitrate/fps.
    @State private var applyingQualityPreset = false

    private var appearancePreference: DM.AppearancePreference {
        DM.AppearancePreference(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            mirrorTab
                .tabItem { Label("Mirror", systemImage: "airplayvideo") }
            privacyTab
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 480, minHeight: 420)
        // Settings is a separate scene — must apply preference here too (Wave 1 + polish).
        .preferredColorScheme(appearancePreference.preferredColorScheme)
        .task {
            cacheBytes = ThumbnailCache.shared.cacheSize()
            refreshDownloadDir()
            refreshScrcpyStatus()
        }
    }

    // MARK: - Tabs

    private var generalTab: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(DM.AppearancePreference.allCases) { pref in
                        Text(pref.label).tag(pref.rawValue)
                    }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Follow System is the default. Light and Dark override macOS appearance for this app only.")
                    .font(.caption)
            }

            Section {
                Toggle("Retry failed downloads once", isOn: $autoRetryTransfers)
                    .help("When a download fails, automatically try again from the partial file. On by default.")
                Toggle("Open queue for multi-file transfers", isOn: $autoShowTransferQueue)
                    .help("When downloading or uploading 2+ items, open the Transfer Queue sheet automatically.")
            } header: {
                Text("Transfers")
            } footer: {
                Text("Interrupted downloads keep a .droidmate-partial file and resume from the last byte.")
                    .font(.caption)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Download folder")
                        Text(downloadDirPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: downloadDirPath, isDirectory: true))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Reset") {
                        UserDefaults.standard.removeObject(forKey: "lastDownloadDir")
                        refreshDownloadDir()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Use the system Downloads folder again")
                }
            } header: {
                Text("Files")
            } footer: {
                Text("⌘S downloads here. ⌥⌘S lets you choose a different location (and updates this folder).")
                    .font(.caption)
            }

            Section {
                Picker("Thumbnail cache limit", selection: $cacheLimitMB) {
                    Text("100 MB").tag(100)
                    Text("200 MB").tag(200)
                    Text("300 MB").tag(300)
                    Text("500 MB").tag(500)
                }
                HStack {
                    Text("Current cache")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Clear Now") {
                        ThumbnailCache.shared.clearAll()
                        cacheBytes = ThumbnailCache.shared.cacheSize()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(cacheBytes == 0)
                }
            } header: {
                Text("Storage")
            }
        }
        .formStyle(.grouped)
    }

    private var mirrorTab: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: scrcpyAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(scrcpyAvailable ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scrcpyAvailable
                             ? String(localized: "scrcpy ready")
                             : String(localized: "scrcpy not found"))
                            .font(.body.weight(.medium))
                        Text(scrcpyAvailable
                             ? scrcpyPathText
                             : String(localized: "Bundled scrcpy is missing from this install."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Recheck") {
                        scrcpy?.refreshAvailability()
                        refreshScrcpyStatus()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } header: {
                Text("scrcpy")
            } footer: {
                Text("Screen mirror includes a portable scrcpy build (Genymobile). No separate install needed.")
                    .font(.caption)
            }

            Section {
                Picker("Quality", selection: $qualityPresetRaw) {
                    ForEach(ScrcpyController.QualityPreset.allCases) { preset in
                        Text(preset.label).tag(preset.rawValue)
                    }
                }
                .onChange(of: qualityPresetRaw) { _, raw in
                    if let p = ScrcpyController.QualityPreset(rawValue: raw), p != .custom {
                        applyingQualityPreset = true
                        ScrcpyController.QualityPreset.apply(p)
                        maxSize = UserDefaults.standard.object(forKey: "mirror.max_size") as? Int ?? maxSize
                        bitrate = UserDefaults.standard.string(forKey: "mirror.bitrate") ?? bitrate
                        fps = UserDefaults.standard.object(forKey: "mirror.fps") as? Int ?? fps
                        DispatchQueue.main.async { applyingQualityPreset = false }
                    }
                }
                .disabled(!scrcpyAvailable)

                if qualityPresetRaw == ScrcpyController.QualityPreset.custom.rawValue {
                    Picker("Resolution (long edge)", selection: $maxSize) {
                        Text("720").tag(720)
                        Text("1080").tag(1080)
                        Text("1920").tag(1920)
                        Text("2560").tag(2560)
                    }
                    Picker("Bitrate", selection: $bitrate) {
                        Text("4 Mbps").tag("4M")
                        Text("8 Mbps").tag("8M")
                        Text("16 Mbps").tag("16M")
                        Text("24 Mbps").tag("24M")
                    }
                    Picker("Max FPS", selection: $fps) {
                        Text("30").tag(30)
                        Text("60").tag(60)
                        Text("90").tag(90)
                    }
                } else {
                    Text("\(maxSize)p · \(bitrate) · \(fps) fps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Optimize for Wi-Fi mirrors", isOn: $wirelessOptimize)
                    .help("On wireless adb, soft-cap at 1080p / 8Mbps / 60fps for lower lag. USB uses your quality preset fully.")
                    .disabled(!scrcpyAvailable)
                Toggle("Audio", isOn: $audioEnabled)
                    .help("Requires scrcpy 2.0+. Streams device audio to your Mac.")
                    .disabled(!scrcpyAvailable)
                Toggle("Float on top", isOn: $alwaysOnTop)
                    .help("Keep the mirror window above other windows. Takes effect on next mirror launch.")
                    .disabled(!scrcpyAvailable)

                if let scrcpy, !scrcpy.runningSerials.isEmpty {
                    Button("Apply & restart mirror") {
                        scrcpy.restartRunningMirrors()
                    }
                    .help("Stop and relaunch active mirrors so capture settings take effect now.")
                }
            } header: {
                Text("Capture")
            } footer: {
                Text("Quality presets cover most cases. Choose Custom for manual resolution / bitrate / fps. Live clips while mirroring use Android screenrecord (max 3 min); for longer video use Start Mirror & Record.")
                    .font(.caption)
            }

            Section {
                Picker("Mouse / touch", selection: $mouseMode) {
                    ForEach(ScrcpyController.MouseMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .help("sdk: Android touch API (default, recommended). uhid: relative HID mouse. View only: no clicks.")
                .disabled(!scrcpyAvailable)
                Picker("Keyboard injection", selection: $keyboardMode) {
                    ForEach(ScrcpyController.KeyboardMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .help("sdk: Android input API (default). uhid: emulated hardware keyboard (configure layout once on device via ⌘K / Alt+K).")
                Toggle("⌘ as shortcut key (recommended)", isOn: $cmdAsShortcutMod)
                    .help("Treat ⌘ like scrcpy’s MOD so ⌘C / ⌘V / ⌘X copy, paste, and cut on the device. Disable only if you need raw Super key events.")
            } header: {
                Text("Input")
            } footer: {
                Text("Click inside the mirror window for normal control. Xiaomi/HyperOS: enable 「USB调试（安全设置）」. Function keys use the same permission.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .onChange(of: maxSize) { _, _ in markCustomFromManualCapture() }
        .onChange(of: bitrate) { _, _ in markCustomFromManualCapture() }
        .onChange(of: fps) { _, _ in markCustomFromManualCapture() }
    }

    private func markCustomFromManualCapture() {
        guard !applyingQualityPreset else { return }
        guard qualityPresetRaw != ScrcpyController.QualityPreset.custom.rawValue else { return }
        qualityPresetRaw = ScrcpyController.QualityPreset.custom.rawValue
    }

    private var privacyTab: some View {
        Form {
            Section {
                Toggle("Mac → Android", isOn: $macToAndroid)
                    .help("Send Mac copy events to the Android clipboard.")
                Toggle("Android → Mac", isOn: $androidToMac)
                    .help("Mirror Android clipboard into NSPasteboard.")
            } header: {
                Text("Clipboard Sync")
            } footer: {
                Text("Off by default. Clipboard text moves only between this Mac and the connected Android device; DroidMate does not keep a clipboard history.")
                    .font(.caption)
            }

            Section {
                Toggle("Mirror Android notifications", isOn: $mirrorAndroidNotifs)
                    .help("Show Android notifications as macOS banners. Off by default — content may include 2FA codes or private messages.")
            } header: {
                Text("Notifications")
            } footer: {
                Text("Notification mirroring is off by default because banners may include private messages or 2FA codes.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        Form {
            Section {
                HStack(spacing: DM.Space.md) {
                    BrandMark(size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DroidMate")
                            .font(.title3.weight(.semibold))
                        Text("A Finder-native Android file manager for Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(appVersion)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.vertical, DM.Space.xs)
            }

            Section {
                Text("This release")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                aboutBullet("Built-in screen mirror with branded Dock icon")
                aboutBullet("Live clips + Start Mirror & Record for long video")
                aboutBullet("Quality presets and Wi-Fi soft-cap")
                aboutBullet("Xiaomi control guide · Finder-class file transfers")
            } header: {
                Text("What's New")
            } footer: {
                Text("Open “Show What's New…” anytime for the full tour.")
                    .font(.caption)
            }

            Section {
                shortcutRow("Search", "⌘F")
                shortcutRow("Refresh folder", "⌘R")
                shortcutRow("Go to Path…", "⇧⌘G")
                shortcutRow("Download", "⌘S")
                shortcutRow("Download to…", "⌥⌘S")
                shortcutRow("Command palette", "⌘K")
                shortcutRow("New folder", "⇧⌘N")
                shortcutRow("List / Grid view", "⌘1 / ⌘2")
                shortcutRow("Toggle hidden files", "⇧⌘.")
                shortcutRow("Transfer queue", "⌘J")
                shortcutRow("Disconnect", "⌘D")
                shortcutRow("Refresh devices", "⇧⌘R")
            } header: {
                Text("Keyboard Shortcuts")
            }

            Section {
                Button("Show Welcome Guide…") {
                    NotificationCenter.default.post(name: .showOnboarding, object: nil)
                }
                Button("Show What's New…") {
                    NotificationCenter.default.post(name: .showWhatsNew, object: nil)
                }
                Button("Reset First-Launch Animation") {
                    UserDefaults.standard.set(false, forKey: "launchSplash.completed")
                }
                Button("Export Diagnostics…") {
                    if DiagnosticsExporter.exportAndReveal() != nil {
                        diagnosticsNote = String(localized: "Diagnostics saved and revealed in Finder.")
                    } else {
                        diagnosticsNote = String(localized: "Could not write diagnostics file.")
                    }
                }
                if let diagnosticsNote {
                    Text(diagnosticsNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Help")
            } footer: {
                Text("Welcome guide: USB debugging & connect tips. Diagnostics include app version, adb/scrcpy paths, and preferences — no phone files.")
                    .font(.caption)
            }

            Section {
                Link(destination: URL(string: "https://github.com/Genymobile/scrcpy")!) {
                    Label("scrcpy on GitHub", systemImage: "link")
                }
                Text("DroidMate is MIT-licensed. Screen mirror is powered by scrcpy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Open Source")
            }
        }
        .formStyle(.grouped)
    }

    private func aboutBullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func shortcutRow(_ name: LocalizedStringKey, _ keys: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(keys)
                .font(.caption.weight(.medium).monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: DM.Radius.sm, style: .continuous)
                        .fill(DM.panelFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DM.Radius.sm, style: .continuous)
                        .strokeBorder(DM.cardStroke, lineWidth: 0.5)
                )
        }
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private func refreshDownloadDir() {
        if let last = UserDefaults.standard.string(forKey: "lastDownloadDir"),
           FileManager.default.fileExists(atPath: last) {
            downloadDirPath = last
        } else {
            downloadDirPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
        }
    }

    private func refreshScrcpyStatus() {
        if let scrcpy {
            scrcpy.refreshAvailability()
            scrcpyAvailable = scrcpy.isAvailable
            scrcpyPathText = scrcpy.availabilityLabel
        } else {
            let probe = ScrcpyController()
            scrcpyAvailable = probe.isAvailable
            scrcpyPathText = probe.availabilityLabel
        }
    }
}
