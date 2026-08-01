import SwiftUI
import UserNotifications

/// Main app entry. Holds the shared DeviceSession and presents either the
/// connection window (no device) or the file browser window (connected).
@main
struct DroidMateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var connMgr = ConnectionManager()
    @StateObject private var menuBar = MenuBarController()
    @StateObject private var scrcpy = ScrcpyController()
    @State private var commandPaletteOpen = false

    init() {
        // Packaging helper: export AppIcon PNG and exit (see build-dmg.sh).
        AppIcon.handleCLIIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            RootView(connMgr: connMgr, scrcpy: scrcpy)
                .onAppear {
                    PreviewController.shared.trimCache()
                    ThumbnailCache.shared.trimCache()
                    TransferNotificationCenter.shared.setup()
                    TransferNotificationCenter.shared.activeSerialProvider = {
                        connMgr.activeEngine?.deviceSerial
                    }
                    if Bundle.main.bundleIdentifier != nil {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
                    }
                    appDelegate.scrcpy = scrcpy
                    appDelegate.connectionManager = connMgr
                    menuBar.scrcpy = scrcpy
                    menuBar.setup(connMgr: connMgr)
                    let oldDragDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("DroidMateDrag", isDirectory: true)
                    try? FileManager.default.removeItem(at: oldDragDir)
                    let tempDragDir = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("DroidMateDrag", isDirectory: true)
                    try? FileManager.default.removeItem(at: tempDragDir)
                    AppIcon.apply()
                    // Bring the app window to front on launch so the user
                    // sees it — but use normal level, not floating.
                    DispatchQueue.main.async {
                        NSApp.activate(ignoringOtherApps: true)
                        for window in NSApp.windows where !window.title.isEmpty {
                            window.makeKeyAndOrderFront(nil)
                        }
                    }
                }
                .onChange(of: connMgr.engines.count) { _, _ in
                    menuBar.rebuildMenu()
                }
                .onChange(of: scrcpy.runningSerials) { _, _ in
                    menuBar.rebuildMenu()
                }
                .sheet(isPresented: $commandPaletteOpen) {
                    CommandPaletteView(isPresented: $commandPaletteOpen, connMgr: connMgr)
                }
        }
        .defaultSize(width: 900, height: 600)
        .windowToolbarStyle(.unified)


        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandMenu("Device") {
                // ⌘R is reserved for refreshing the file list while browsing.
                Button("Refresh devices") { Task { await refreshDevices() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Disconnect") {
                    if let engine = connMgr.activeEngine {
                        // Transfer-in-progress → RootView confirmation dialog.
                        connMgr.requestDisconnect(engine.deviceSerial)
                    }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(connMgr.engines.isEmpty)
            }

            CommandMenu("Commands") {
                Button("Command Palette…") { commandPaletteOpen = true }
                    .keyboardShortcut("k", modifiers: .command)
            }

            CommandGroup(replacing: .help) {
                Button("DroidMate Help") {
                    NotificationCenter.default.post(name: .showOnboarding, object: nil)
                }
                Button("What's New in DroidMate") {
                    NotificationCenter.default.post(name: .showWhatsNew, object: nil)
                }
                Divider()
                Button("Export Diagnostics…") {
                    _ = DiagnosticsExporter.exportAndReveal()
                }
            }
        }

        Settings {
            SettingsView(scrcpy: scrcpy)
        }
    }

    private func refreshDevices() async {
        NotificationCenter.default.post(name: .refreshDevices, object: nil)
    }
}

private struct RootView: View {
    @ObservedObject var connMgr: ConnectionManager
    @ObservedObject var scrcpy: ScrcpyController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("onboarding.completed") private var onboardingCompleted = false
    /// First-open brand splash only — never again after completed once.
    @AppStorage("launchSplash.completed") private var splashCompleted = false
    @AppStorage(AppVersioning.lastSeenWhatsNewKey) private var lastSeenWhatsNew = ""
    @State private var showOnboarding = false
    @State private var showSplash = false
    @State private var showWhatsNew = false
    /// Main UI fades in under the splash so the handoff isn't a hard cut.
    @State private var mainRevealed = false

    /// Session pool non-empty → stay in the browser even while handshaking or
    /// briefly failed. Only return to the connection workspace when every
    /// device is gone (avoids kicking the user out mid-browse on a blip).
    private var hasSession: Bool { connMgr.activeEngine != nil }

    var body: some View {
        ZStack {
            // Main UI always mounted (warms layout while splash plays).
            Group {
                if let engine = connMgr.activeEngine {
                    FileBrowserView(connMgr: connMgr, engine: engine, client: engine.files, serial: engine.deviceSerial, scrcpy: scrcpy)
                        .id(engine.deviceSerial)
                } else {
                    ConnectionView(connMgr: connMgr)
                }
            }
            .opacity(mainRevealed ? 1 : 0)
            // No scale transition here — it fought the splash exit and felt like a hitch.

            if showSplash {
                LaunchSplashView {
                    // Splash already animated itself out. Drop it without a
                    // second parent animation, then soft-reveal the main UI.
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        showSplash = false
                        splashCompleted = true
                    }
                    withAnimation(reduceMotion
                                  ? .easeOut(duration: 0.18)
                                  : .easeOut(duration: 0.32)) {
                        mainRevealed = true
                    }
                    // Onboarding / What's New after UI is settled.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        presentPostLaunchSheets()
                    }
                }
                .zIndex(100)
                // Identity stable; removal is non-animated (see disablesAnimations above).
                .transition(.identity)
            }
        }
        .animation(reduceMotion ? AppSpring.crossfade : AppSpring.standard,
                   value: hasSession)
        .onAppear {
            if splashCompleted {
                // Returning user: show main UI immediately, no splash.
                mainRevealed = true
                DispatchQueue.main.async { presentPostLaunchSheets() }
            } else {
                // First open: splash covers a pre-mounted, still-hidden main UI.
                showSplash = true
                mainRevealed = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showOnboarding)) { _ in
            showOnboarding = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showWhatsNew)) { _ in
            showWhatsNew = true
        }
        .confirmationDialog(
            String(localized: "Disconnect this device?"),
            isPresented: Binding(
                get: { !connMgr.pendingDisconnectSerials.isEmpty },
                set: { if !$0 { connMgr.cancelPendingDisconnect() } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Disconnect"), role: .destructive) {
                connMgr.confirmPendingDisconnect()
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                connMgr.cancelPendingDisconnect()
            }
        } message: {
            let serials = connMgr.pendingDisconnectSerials
            let transferring = serials.contains { s in
                connMgr.engines.first(where: { $0.deviceSerial == s })?.files.isTransferring == true
            }
            let wireless = serials.contains(where: { $0.contains(":") })
            if transferring {
                Text(String(localized: "Transfers are still in progress. Disconnecting will cancel them."))
            } else if wireless {
                Text(String(localized: "This drops the wireless adb link. You can reconnect anytime from the connection screen."))
            } else {
                Text(String(localized: "You can reconnect anytime from the connection screen."))
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView {
                onboardingCompleted = true
                // First-time users already got the tour — don't stack What's New.
                lastSeenWhatsNew = AppVersioning.shortVersion
                showOnboarding = false
            }
            .frame(minWidth: 560, idealWidth: 600, minHeight: 440, idealHeight: 480)
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView(version: AppVersioning.shortVersion) {
                lastSeenWhatsNew = AppVersioning.shortVersion
                showWhatsNew = false
            }
        }
    }

    /// Prefer onboarding first; What's New only when upgrading to a new short version.
    private func presentPostLaunchSheets() {
        if !onboardingCompleted {
            showOnboarding = true
            return
        }
        maybeShowWhatsNew()
    }

    private func maybeShowWhatsNew() {
        guard onboardingCompleted else { return }
        let current = AppVersioning.shortVersion
        guard !current.isEmpty, current != "0" else { return }
        // First launch after update: lastSeen empty or older short version.
        guard lastSeenWhatsNew != current else { return }
        // If never set (legacy install), still show once for 0.2+.
        showWhatsNew = true
    }
}

extension Notification.Name {
    static let openAppManager = Notification.Name("openAppManager")
    static let refreshDevices = Notification.Name("refreshDevices")
    static let newFolder = Notification.Name("newFolder")
    static let openTransfers = Notification.Name("openTransfers")
    static let focusSearch = Notification.Name("focusSearch")
    static let toggleViewMode = Notification.Name("toggleViewMode")
    static let showOnboarding = Notification.Name("showOnboarding")
    static let showWhatsNew = Notification.Name("showWhatsNew")
    static let showGoToPath = Notification.Name("showGoToPath")
    /// Posted by ConnectionManager when a device session is removed. `object` is the serial `String`.
    static let deviceSessionRemoved = Notification.Name("deviceSessionRemoved")
}
