import AppKit
import Foundation
import os

private let log = Logger(subsystem: "com.droidmate", category: "ScrcpyController")

@MainActor
final class ScrcpyController: ObservableObject {

    @Published private(set) var runningSerials: Set<String> = []
    /// Serials still probing inject / opening scrcpy (process not ready yet).
    @Published private(set) var launchingSerials: Set<String> = []
    /// Short status for the launching phase (banner + control bar).
    @Published private(set) var launchStatusText: String?
    @Published private(set) var launchError: String?
    /// Non-fatal control warning (e.g. Xiaomi blocked inject → using HID).
    @Published var controlHint: String?
    /// True when a usable scrcpy binary was found (refreshed via `refreshAvailability`).
    @Published private(set) var isAvailable: Bool = false
    @Published private(set) var scrcpyPath: String?
    @Published private(set) var mirrorPids: [String: Int32] = [:]
    @Published private(set) var recordingSerials: Set<String> = []
    /// When recording started for each serial (for live elapsed timer in the control bar).
    @Published private(set) var recordingStartedAt: [String: Date] = [:]
    /// Last successfully saved recording (Downloads).
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var recordingError: String?
    private var recordingProcesses: [String: Process] = [:]
    private var recordingRemotePaths: [String: String] = [:]
    /// Serials whose recording was auto-stopped at the adb time limit (for UI copy).
    private var recordingHitTimeLimit: Set<String> = []
    /// Start next mirror with scrcpy `--record` (same-session, no 3-minute adb cap).
    private var recordOnLaunch: Set<String> = []
    /// Local mp4 path when mirror was started with session recording.
    private var sessionRecordURLs: [String: URL] = [:]
    private enum RecordingKind {
        case adb            // adb screenrecord while mirror runs (≤3 min)
        case sessionScrcpy  // same scrcpy process `--record`
        case headlessScrcpy // recorder host app only
    }
    private var recordingKinds: [String: RecordingKind] = [:]

    /// Legacy Process handles (fallback only).
    private var processes: [String: Process] = [:]
    /// Preferred: apps launched via NSWorkspace (Dock uses .app icon/name).
    private var mirrorApps: [String: NSRunningApplication] = [:]
    private var recorderApps: [String: NSRunningApplication] = [:]
    private var terminateObserver: NSObjectProtocol?
    private var willTerminateObserver: NSObjectProtocol?
    private var deviceRemovedObserver: NSObjectProtocol?

    private var intendingToRun: Set<String> = []
    private var crashCount: [String: Int] = [:]
    private var launchTime: [String: Date] = [:]

    private var cachedScrcpyPath: String?
    private var cachedServerPath: String?
    private var didLookupScrcpy = false
    private var isUsingBundled = false

    static let brewInstallCommand = "brew install scrcpy"

    /// `adb shell screenrecord --time-limit` (seconds). Exposed for UI countdown.
    nonisolated static let adbScreenRecordTimeLimitSeconds: TimeInterval = 180

    /// UserDefaults: capture quality preset (`smooth` / `balanced` / `high` / `custom`).
    nonisolated static let qualityPresetKey = "mirror.quality_preset"
    /// When true (default), wireless serials get a soft cap on size/bitrate/fps.
    nonisolated static let wirelessOptimizeKey = "mirror.wireless_optimize"

    /// One-tap quality profiles (writes through to max_size / bitrate / fps when not custom).
    enum QualityPreset: String, CaseIterable, Identifiable, Sendable {
        case smooth
        case balanced
        case high
        case custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .smooth: return String(localized: "Smooth (720p · 30fps)")
            case .balanced: return String(localized: "Balanced (1080p · 60fps)")
            case .high: return String(localized: "High (1920p · 60fps)")
            case .custom: return String(localized: "Custom")
            }
        }
        /// Fixed params for non-custom presets.
        var params: (maxSize: Int, bitrate: String, fps: Int)? {
            switch self {
            case .smooth: return (720, "4M", 30)
            case .balanced: return (1080, "8M", 60)
            case .high: return (1920, "8M", 60)
            case .custom: return nil
            }
        }
        nonisolated static func resolved(from defaults: UserDefaults = .standard) -> QualityPreset {
            let raw = defaults.string(forKey: qualityPresetKey) ?? QualityPreset.balanced.rawValue
            return QualityPreset(rawValue: raw) ?? .balanced
        }
        /// Apply preset into UserDefaults (no-op for `.custom`).
        nonisolated static func apply(_ preset: QualityPreset, to defaults: UserDefaults = .standard) {
            defaults.set(preset.rawValue, forKey: qualityPresetKey)
            guard let p = preset.params else { return }
            defaults.set(p.maxSize, forKey: "mirror.max_size")
            defaults.set(p.bitrate, forKey: "mirror.bitrate")
            defaults.set(p.fps, forKey: "mirror.fps")
        }
    }

    /// Resolve capture size/bitrate/fps for a launch (preset + optional wireless soft-cap).
    nonisolated static func resolveCaptureParams(
        serial: String,
        defaults: UserDefaults = .standard
    ) -> (maxSize: Int, bitrate: String, fps: Int) {
        let preset = QualityPreset.resolved(from: defaults)
        var maxSize: Int
        var bitrate: String
        var fps: Int
        if let p = preset.params {
            maxSize = p.maxSize
            bitrate = p.bitrate
            fps = p.fps
        } else {
            maxSize = (defaults.object(forKey: "mirror.max_size") as? Int) ?? 1080
            bitrate = defaults.string(forKey: "mirror.bitrate") ?? "8M"
            fps = (defaults.object(forKey: "mirror.fps") as? Int) ?? 60
        }
        let wirelessOpt: Bool = {
            if defaults.object(forKey: wirelessOptimizeKey) == nil { return true }
            return defaults.bool(forKey: wirelessOptimizeKey)
        }()
        // Wireless adb serials look like `192.168.x.x:5555`.
        if wirelessOpt, serial.contains(":") {
            maxSize = min(maxSize, 1080)
            if bitrate == "16M" || bitrate == "24M" { bitrate = "8M" }
            fps = min(fps, 60)
        }
        return (maxSize, bitrate, fps)
    }

    private enum HostRole: String {
        /// Mirror: real Dock app (branded icon, focusable SDL window).
        case mirror
        /// Recorder: agent app (LSUIElement) — no extra Dock tile for headless capture.
        case recorder
    }

    init() {
        // Eager lookup so Settings / UI can show install status without launching.
        _ = findScrcpy()
        isAvailable = cachedScrcpyPath != nil
        scrcpyPath = cachedScrcpyPath
        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            Task { @MainActor in
                guard let self, let pid else { return }
                self.handleTerminatedPid(pid)
            }
        }
        // Quit must not leave orphan scrcpy / recorder processes.
        // Call stopAll *synchronously* on the main queue — a `Task {}` may
        // never run before the process exits, leaving scrcpy orphaned.
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.stopAll()
            }
        }
        // Disconnect / session tear-down should stop that device's mirror + recording.
        deviceRemovedObserver = NotificationCenter.default.addObserver(
            forName: .deviceSessionRemoved,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let serial = note.object as? String
            Task { @MainActor in
                guard let self, let serial else { return }
                if self.recordingSerials.contains(serial) {
                    self.stopRecording(serial: serial)
                }
                self.stop(serial: serial)
            }
        }
    }

    /// Re-scan bundled + PATH locations.
    func refreshAvailability() {
        didLookupScrcpy = false
        cachedScrcpyPath = nil
        cachedServerPath = nil
        isUsingBundled = false
        _ = findScrcpy()
        isAvailable = cachedScrcpyPath != nil
        scrcpyPath = cachedScrcpyPath
    }

    /// Human-readable source for Settings (“Bundled” vs Homebrew path).
    var availabilityLabel: String {
        guard let path = scrcpyPath else {
            return String(localized: "scrcpy not found")
        }
        if isUsingBundled {
            return String(localized: "Bundled scrcpy (ready)")
        }
        return path
    }

    private func findScrcpy() -> String? {
        if didLookupScrcpy { return cachedScrcpyPath }
        didLookupScrcpy = true

        // 1) Official portable binary shipped inside the app (preferred).
        if let bundled = resolveBundledScrcpy() {
            cachedScrcpyPath = bundled
            isUsingBundled = true
            return bundled
        }

        // 2) Homebrew / PATH fallback.
        let candidates = [
            "/opt/homebrew/bin/scrcpy",
            "/usr/local/bin/scrcpy",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedScrcpyPath = path
                isUsingBundled = false
                return path
            }
        }
        let task = Process()
        task.launchPath = "/usr/bin/which"
        task.arguments = ["scrcpy"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let out, !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) {
            cachedScrcpyPath = out
            isUsingBundled = false
            return out
        }
        return nil
    }

    /// Locate scrcpy + scrcpy-server in the resource bundle, copy to Application
    /// Support (writable, executable, same pattern as adb) so Gatekeeper is happy.
    private func resolveBundledScrcpy() -> String? {
        let fm = FileManager.default
        guard let binURL = bundledResourceURL(named: "scrcpy"),
              fm.isExecutableFile(atPath: binURL.path) || fm.fileExists(atPath: binURL.path)
        else { return nil }

        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DroidMate", isDirectory: true)
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)

        let destBin = support.appendingPathComponent("scrcpy")
        let destServer = support.appendingPathComponent("scrcpy-server")

        // Refresh cache when the bundled binary changes size (app update).
        let needCopy: Bool = {
            guard fm.isExecutableFile(atPath: destBin.path) else { return true }
            let a = (try? binURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            let b = (try? destBin.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
            return a != b
        }()

        if needCopy {
            try? fm.removeItem(at: destBin)
            try? fm.copyItem(at: binURL, to: destBin)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destBin.path)
            // Clear quarantine so nested binary can run without user panic.
            _ = try? Process.run(
                URL(fileURLWithPath: "/usr/bin/xattr"),
                arguments: ["-dr", "com.apple.quarantine", destBin.path]
            )
        }

        if let serverURL = bundledResourceURL(named: "scrcpy-server") {
            let needServer: Bool = {
                guard fm.fileExists(atPath: destServer.path) else { return true }
                let a = (try? serverURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                let b = (try? destServer.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
                return a != b
            }()
            if needServer {
                try? fm.removeItem(at: destServer)
                try? fm.copyItem(at: serverURL, to: destServer)
            }
            cachedServerPath = destServer.path
        } else {
            let sibling = binURL.deletingLastPathComponent().appendingPathComponent("scrcpy-server")
            if fm.fileExists(atPath: sibling.path) {
                cachedServerPath = sibling.path
            }
        }

        guard fm.isExecutableFile(atPath: destBin.path) else { return nil }
        return destBin.path
    }

    private func bundledResourceURL(named name: String) -> URL? {
        // Packaged .app first (flattened Contents/Resources). Never use
        // Bundle.module — it fatalErrors when the SPM resource bundle is absent.
        if let u = ResourceBundle.url(forResource: name, withExtension: nil, subdirectory: "Bin") {
            return u
        }
        if let u = ResourceBundle.url(forResource: name, withExtension: nil) {
            return u
        }
        // Dev: binary next to sources when running unbundled tests
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Capture/
            .deletingLastPathComponent() // Sources/DroidMate
            .appendingPathComponent("Bin")
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        return nil
    }

    private func adbEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let adbPath = AdbLocator.shared.findAdb()
        if let adbPath {
            let adbDir = (adbPath as NSString).deletingLastPathComponent
            env["PATH"] = "\(adbDir):\(env["PATH"] ?? "")"
            env["ANDROID_SDK_ROOT"] = (adbDir as NSString).deletingLastPathComponent
            // scrcpy respects ADB= full path to adb binary
            env["ADB"] = adbPath
        }
        // Point portable scrcpy at our bundled server jar (required).
        if let server = cachedServerPath ?? bundledResourceURL(named: "scrcpy-server")?.path {
            env["SCRCPY_SERVER_PATH"] = server
        }
        return env
    }

    // MARK: - Dock-friendly host .apps

    /// Executable name inside the host .app (not "scrcpy" — Dock must never show a bare binary label).
    private static func hostExecutableName(for role: HostRole) -> String {
        role == .mirror ? "DroidMateMirror" : "DroidMateRecorder"
    }

    /// Mirror: branded Dock tile. Recorder: agent app (no Dock tile).
    /// - Parameter force: rebuild exec + metadata even when stamp/size match (used on open failure retry).
    private func ensureHostApp(role: HostRole, scrcpyBinaryPath: String, force: Bool = false) -> URL? {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DroidMate", isDirectory: true)
        let appName = role == .mirror ? "DroidMate Mirror.app" : "DroidMate Recorder.app"
        let bundleId = role == .mirror ? "com.droidmate.mirror" : "com.droidmate.recorder"
        let displayName = role == .mirror ? "DroidMate Mirror" : "DroidMate Recorder"
        let execName = Self.hostExecutableName(for: role)
        let appURL = support.appendingPathComponent(appName, isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let execURL = macos.appendingPathComponent(execName)
        let legacyExecURL = macos.appendingPathComponent("scrcpy") // pre-v8 name
        let plistURL = contents.appendingPathComponent("Info.plist")
        let icnsURL = resources.appendingPathComponent("AppIcon.icns")
        let pkgInfo = contents.appendingPathComponent("PkgInfo")

        try? fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try? fm.createDirectory(at: resources, withIntermediateDirectories: true)

        // Drop legacy "scrcpy" binary name so Dock never labels the tile "scrcpy"/"exec".
        if fm.fileExists(atPath: legacyExecURL.path) {
            try? fm.removeItem(at: legacyExecURL)
        }

        let src = URL(fileURLWithPath: scrcpyBinaryPath)
        let needExec: Bool = {
            if force { return true }
            guard fm.isExecutableFile(atPath: execURL.path) else { return true }
            let a = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            let b = (try? execURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
            return a != b
        }()
        if needExec {
            try? fm.removeItem(at: execURL)
            do {
                try fm.copyItem(at: src, to: execURL)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execURL.path)
                _ = try? Process.run(
                    URL(fileURLWithPath: "/usr/bin/xattr"),
                    arguments: ["-dr", "com.apple.quarantine", execURL.path]
                )
            } catch {
                log.error("host copy failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        // v8: branded exec name (DroidMateMirror), sign only when content changes,
        // never every launch (codesign thrash → Dock icon flicker / "exec" tile).
        let stamp = "droidmate-host-v8-\(role.rawValue)"
        let stampURL = resources.appendingPathComponent(".host-stamp")
        let needMeta = force
            || !fm.fileExists(atPath: plistURL.path)
            || ((try? String(contentsOf: stampURL, encoding: .utf8)) != stamp)
            || !fm.fileExists(atPath: icnsURL.path)

        if needMeta {
            var plist: [String: Any] = [
                "CFBundleDevelopmentRegion": "en",
                "CFBundleDisplayName": displayName,
                "CFBundleExecutable": execName,
                "CFBundleIconFile": "AppIcon",
                "CFBundleIconName": "AppIcon",
                "CFBundleIdentifier": bundleId,
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": displayName,
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "13.0",
                "NSHighResolutionCapable": true,
                "NSSupportsAutomaticGraphicsSwitching": true,
                "NSHumanReadableCopyright": "Powered by scrcpy · DroidMate",
            ]
            // Recorder is headless — hide from Dock. Mirror must show branded tile.
            if role == .recorder {
                plist["LSUIElement"] = true
            }
            do {
                let data = try PropertyListSerialization.data(
                    fromPropertyList: plist, format: .xml, options: 0
                )
                try data.write(to: plistURL)
                try "APPL????".write(to: pkgInfo, atomically: true, encoding: .utf8)
                try stamp.write(to: stampURL, atomically: true, encoding: .utf8)
            } catch {
                log.error("host plist failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
            writeHostIcon(to: icnsURL)
            if !fm.fileExists(atPath: icnsURL.path) {
                log.error("host icon missing after write — Dock will look generic")
            }
        }

        // Only re-sign / re-register when something actually changed.
        // Re-signing every launch invalidates Launch Services icon cache and can
        // briefly (or persistently) show a black generic "exec" tile.
        if needExec || needMeta {
            _ = try? Process.run(
                URL(fileURLWithPath: "/usr/bin/xattr"),
                arguments: ["-dr", "com.apple.quarantine", appURL.path]
            )
            _ = try? Process.run(
                URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--force", "--deep", "--sign", "-", appURL.path]
            )
            _ = try? Process.run(
                URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"),
                arguments: ["-f", appURL.path]
            )
            log.info("host app refreshed role=\(role.rawValue, privacy: .public) exec=\(needExec) meta=\(needMeta)")
        }

        guard fm.isExecutableFile(atPath: execURL.path),
              fm.fileExists(atPath: plistURL.path) else {
            log.error("host app incomplete at \(appURL.path, privacy: .public)")
            return nil
        }
        return appURL
    }

    private func writeHostIcon(to icnsURL: URL) {
        let fm = FileManager.default
        // 1) Prefer already-built icns from the main app (reliable).
        let icnsCandidates: [URL?] = [
            Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/AppIcon.icns"),
        ]
        for c in icnsCandidates.compactMap({ $0 }) where fm.fileExists(atPath: c.path) {
            try? fm.removeItem(at: icnsURL)
            try? fm.copyItem(at: c, to: icnsURL)
            if fm.fileExists(atPath: icnsURL.path) { return }
        }

        // 2) Build from brand PNG via sips + iconutil.
        var pngCandidates: [URL] = []
        if let u = ResourceBundle.url(forResource: "AppIcon", withExtension: "png", subdirectory: "Brand") {
            pngCandidates.append(u)
        }
        if let u = ResourceBundle.url(forResource: "AppIcon", withExtension: "png") {
            pngCandidates.append(u)
        }
        guard let pngURL = pngCandidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            log.error("host icon: no brand PNG/icns found")
            return
        }

        let work = fm.temporaryDirectory.appendingPathComponent("DMHostIcon-\(UUID().uuidString)")
        let iconset = work.appendingPathComponent("AppIcon.iconset")
        try? fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        for s in [16, 32, 128, 256, 512] {
            let out1 = iconset.appendingPathComponent("icon_\(s)x\(s).png")
            let out2 = iconset.appendingPathComponent("icon_\(s)x\(s)@2x.png")
            _ = try? Process.run(
                URL(fileURLWithPath: "/usr/bin/sips"),
                arguments: ["-z", "\(s)", "\(s)", pngURL.path, "--out", out1.path]
            )
            _ = try? Process.run(
                URL(fileURLWithPath: "/usr/bin/sips"),
                arguments: ["-z", "\(s * 2)", "\(s * 2)", pngURL.path, "--out", out2.path]
            )
        }
        _ = try? Process.run(
            URL(fileURLWithPath: "/usr/bin/iconutil"),
            arguments: ["-c", "icns", iconset.path, "-o", icnsURL.path]
        )
        try? fm.removeItem(at: work)
        if !fm.fileExists(atPath: icnsURL.path) {
            log.error("host icon: iconutil failed")
        }
    }

    private var deviceModels: [String: String] = [:]

    /// Unified entry for toolbar / sidebar / menu: start mirror + floating control bar.
    /// - Parameter recordSession: when true, same scrcpy process also writes `--record`
    ///   (no 3-minute adb cap; file finalizes when the mirror stops).
    @discardableResult
    func startMirror(serial: String, deviceModel: String? = nil, recordSession: Bool = false) -> Bool {
        guard isScrcpyAvailable || findScrcpy() != nil else {
            launchError = String(localized:
                "Screen mirror could not find scrcpy. Reinstall DroidMate.")
            return false
        }
        guard !runningSerials.contains(serial) else { return false }
        if recordSession {
            recordOnLaunch.insert(serial)
        } else {
            recordOnLaunch.remove(serial)
        }
        launch(serial: serial, deviceModel: deviceModel)
        MirrorControlPanel.shared.show(
            for: serial,
            deviceModel: deviceModel ?? deviceModels[serial],
            scrcpy: self
        )
        return true
    }

    /// Stop + relaunch every active mirror so Settings capture/input changes apply.
    func restartRunningMirrors() {
        let snapshot = Array(runningSerials)
        for serial in snapshot {
            let model = deviceModels[serial]
            let wasSessionRec = recordingKinds[serial] == .sessionScrcpy
            stop(serial: serial)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self else { return }
                _ = self.startMirror(serial: serial, deviceModel: model, recordSession: wasSessionRec)
            }
        }
    }

    /// Whether the scrcpy process is up (keys / screenshot / record allowed).
    func isMirrorReady(serial: String) -> Bool {
        runningSerials.contains(serial)
            && !launchingSerials.contains(serial)
            && mirrorPids[serial] != nil
    }

    /// True while inject probe or openApplication is still in flight.
    func isLaunching(serial: String) -> Bool {
        launchingSerials.contains(serial)
    }

    func launch(serial: String, deviceModel: String? = nil) {
        if let deviceModel { deviceModels[serial] = deviceModel }
        guard !runningSerials.contains(serial) else { return }
        refreshAvailability()
        guard let scrcpy = findScrcpy() else {
            launchError = String(localized:
                "Screen mirror could not find scrcpy. Reinstall DroidMate, or install via Homebrew:\n\n  brew install scrcpy")
            log.error("scrcpy not found (bundled + system)")
            return
        }
        launchError = nil
        controlHint = nil

        intendingToRun.insert(serial)
        launchTime[serial] = Date()
        runningSerials.insert(serial)
        launchingSerials.insert(serial)
        launchStatusText = String(localized: "Checking phone control…")

        // Probe inject permission off the main actor (adb shell can block).
        // Hop back via a MainActor method so we never capture `self` into a
        // task-isolated closure (Swift 6.2+ strict concurrency).
        let path = scrcpy
        Task { [weak self] in
            let injectOK = await Task.detached(priority: .userInitiated) {
                Self.canInjectInputEvents(serial: serial)
            }.value
            await self?.finishLaunchAfterInjectProbe(
                serial: serial,
                scrcpyPath: path,
                injectOK: injectOK
            )
        }
    }

    /// Continues `launch` after the inject probe. Always MainActor.
    private func finishLaunchAfterInjectProbe(
        serial: String,
        scrcpyPath: String,
        injectOK: Bool
    ) {
        guard intendingToRun.contains(serial) else { return }
        if !injectOK {
            // Ask the user — do NOT silently force uhid (captures the mouse inside the window).
            let choice = promptWhenInjectBlocked(serial: serial)
            switch choice {
            case .cancel:
                abortLaunch(serial: serial)
                return
            case .openSettingsAndLaunchSDK:
                Self.openDeveloperSettings(serial: serial)
                controlHint = String(localized:
                    "On the phone: enable 「USB调试（安全设置）」→ unplug & replug USB → start Mirror again.")
                launchStatusText = String(localized: "Starting mirror…")
                startMirrorProcess(serial: serial, scrcpyPath: scrcpyPath, inputMode: .sdk)
            case .launchHID:
                controlHint = String(localized:
                    "HID mode: mouse is captured in the window. Press Left Alt to free the cursor.")
                launchStatusText = String(localized: "Starting mirror (HID)…")
                startMirrorProcess(serial: serial, scrcpyPath: scrcpyPath, inputMode: .hid)
            }
        } else {
            launchStatusText = String(localized: "Starting mirror…")
            startMirrorProcess(serial: serial, scrcpyPath: scrcpyPath, inputMode: .userDefaults)
        }
    }

    private func abortLaunch(serial: String) {
        intendingToRun.remove(serial)
        launchingSerials.remove(serial)
        runningSerials.remove(serial)
        launchTime.removeValue(forKey: serial)
        recordOnLaunch.remove(serial)
        if recordingKinds[serial] == .sessionScrcpy {
            recordingSerials.remove(serial)
            recordingStartedAt.removeValue(forKey: serial)
            recordingKinds.removeValue(forKey: serial)
            if let url = sessionRecordURLs.removeValue(forKey: serial) {
                recordingLocalURLs.removeValue(forKey: serial)
                try? FileManager.default.removeItem(at: url)
            }
        }
        if launchingSerials.isEmpty { launchStatusText = nil }
    }

    /// Call when the mirror process is known live (pid assigned).
    private func markMirrorReady(serial: String, pid: Int32, app: NSRunningApplication?) {
        launchingSerials.remove(serial)
        if launchingSerials.isEmpty { launchStatusText = nil }
        mirrorPids[serial] = pid
        if let app { mirrorApps[serial] = app }
        crashCount.removeValue(forKey: serial)
        log.info("mirror ready serial=…\(serial.suffix(8), privacy: .public) pid=\(pid)")

        // One-time tip for first successful mirror this install.
        let tipKey = "mirror.first_ready_tip_shown"
        if !UserDefaults.standard.bool(forKey: tipKey) {
            UserDefaults.standard.set(true, forKey: tipKey)
            if controlHint == nil || controlHint?.isEmpty == true {
                let tip = String(localized:
                    "Mirror is ready — click inside the window to control the phone. Floating bar: keys, screenshot, record.")
                controlHint = tip
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    if self?.controlHint == tip { self?.controlHint = nil }
                }
            }
        }
    }

    private enum InjectBlockedChoice {
        case cancel
        case openSettingsAndLaunchSDK
        case launchHID
    }

    /// Modal when the phone rejects INJECT_EVENTS (scrcpy sdk + function keys all need this).
    private func promptWhenInjectBlocked(serial: String) -> InjectBlockedChoice {
        let alert = NSAlert()
        alert.messageText = String(localized: "Phone blocks remote control")
        alert.informativeText = String(localized: """
        Common on Xiaomi / HyperOS. The screen can still mirror, but taps and keys need one setting:

        1. Open Developer options (we can open it)
        2. Turn ON 「USB调试（安全设置）」 / USB debugging (Security settings)
        3. Unplug USB, plug back in
        4. Start Mirror again

        Or try experimental HID (mouse trapped until you press Left Alt).
        """)
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Open settings & start"))
        alert.addButton(withTitle: String(localized: "HID (experimental)"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .openSettingsAndLaunchSDK
        case .alertSecondButtonReturn: return .launchHID
        default: return .cancel
        }
    }

    /// Open Android Developer options so the user can enable Security USB debugging.
    nonisolated static func openDeveloperSettings(serial: String) {
        guard let adb = AdbLocator.shared.findAdb() else { return }
        _ = try? AdbRunner.run(adb, args: [
            "-s", serial, "shell", "am", "start",
            "-a", "android.settings.APPLICATION_DEVELOPMENT_SETTINGS",
        ])
    }

    /// `adb shell input` / scrcpy `--mouse=sdk` need INJECT_EVENTS. Many Xiaomi/HyperOS
    /// builds return SecurityException until “USB debugging (Security settings)” is on.
    /// Bounded to ~3s so a hung adb never blocks mirror launch forever.
    nonisolated static func canInjectInputEvents(serial: String) -> Bool {
        guard let adb = AdbLocator.shared.findAdb() else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: adb)
        proc.arguments = ["-s", serial, "shell", "input", "keyevent", "0"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return true // can't probe — don't block launch
        }
        let deadline = Date().addingTimeInterval(3)
        while proc.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
            log.error("inject probe timed out for \(serial.suffix(8), privacy: .public)")
            return true // assume ok; scrcpy will surface control failures
        }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let msg = String(data: data, encoding: .utf8) ?? ""
        if proc.terminationStatus == 0 { return true }
        if msg.localizedCaseInsensitiveContains("SecurityException")
            || msg.localizedCaseInsensitiveContains("INJECT_EVENTS")
            || msg.localizedCaseInsensitiveContains("Injecting input") {
            return false
        }
        return true
    }

    private enum MirrorInputMode {
        /// Settings pickers (`--mouse=` / `--keyboard=`).
        case userDefaults
        /// Normal scrcpy control (absolute mouse). Needs INJECT_EVENTS on device.
        case sdk
        /// Relative HID; mouse captured in window. May work when inject is blocked.
        case hid
    }

    private func startMirrorProcess(serial: String, scrcpyPath: String, inputMode: MirrorInputMode) {
        let defaults = UserDefaults.standard
        let capture = Self.resolveCaptureParams(serial: serial, defaults: defaults)
        let alwaysOnTop = defaults.bool(forKey: "ui.always_on_top")
        let audioEnabled = defaults.bool(forKey: "audio.enabled")
        let model = deviceModels[serial] ?? "Android"
        let windowTitle = "DroidMate · \(model)"
        let wantSessionRecord = recordOnLaunch.remove(serial) != nil

        // Low-latency defaults matching stock scrcpy (video-buffer 0 is default; pass
        // explicitly so user prefs / older builds cannot reintroduce display lag).
        var args = [
            "--serial", serial,
            "--max-size", String(capture.maxSize),
            "--video-bit-rate", capture.bitrate,
            "--max-fps", String(capture.fps),
            "--video-buffer", "0",
            "--render-driver", "metal",
            "--window-title", windowTitle,
            "--stay-awake",
        ]

        switch inputMode {
        case .userDefaults:
            args.append(contentsOf: Self.mouseArgs(from: defaults))
            args.append(contentsOf: Self.keyboardArgs(from: defaults))
        case .sdk:
            // Stock scrcpy-style control: absolute pointer, normal click-to-tap.
            args.append(contentsOf: ["--mouse=sdk", "--keyboard=sdk"])
            args.append(contentsOf: ["--shortcut-mod", "lalt,lsuper"])
        case .hid:
            args.append(contentsOf: ["--mouse=uhid", "--keyboard=uhid"])
        }
        if !audioEnabled { args.append("--no-audio") }
        if alwaysOnTop { args.append("--always-on-top") }

        // Same-session recording: one encode path, no adb 3-minute cap.
        if wantSessionRecord {
            let staging = Self.recordingStagingDirectory()
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let url = staging.appendingPathComponent("DroidMate-\(fmt.string(from: Date())).mp4")
            try? FileManager.default.removeItem(at: url)
            args.append(contentsOf: ["--record", url.path])
            sessionRecordURLs[serial] = url
            recordingLocalURLs[serial] = url
            recordingSerials.insert(serial)
            recordingStartedAt[serial] = Date()
            recordingKinds[serial] = .sessionScrcpy
            recordingError = nil
            lastRecordingURL = nil
            controlHint = String(localized:
                "Session recording on — file saves when you stop the mirror.")
            log.info("session --record → \(url.lastPathComponent, privacy: .public)")
        }

        if serial.contains(":") {
            log.info("mirror wireless soft-cap \(capture.maxSize)p \(capture.bitrate) \(capture.fps)fps")
        }

        // Branded host .app ONLY path for Dock icon + proper focus.
        // Bare Process shows a black "exec" tile — never use it as the happy path.
        let launchArgs = args
        let launchScrcpy = scrcpyPath
        let launchMode = inputMode

        openMirrorHostApp(
            serial: serial,
            scrcpyPath: launchScrcpy,
            args: launchArgs,
            inputMode: launchMode,
            forceHostRebuild: false,
            attempt: 1
        )
    }

    /// Launch mirror via NSWorkspace host .app. Retries once with a forced host rebuild.
    private func openMirrorHostApp(
        serial: String,
        scrcpyPath: String,
        args: [String],
        inputMode: MirrorInputMode,
        forceHostRebuild: Bool,
        attempt: Int
    ) {
        guard let appURL = ensureHostApp(
            role: .mirror,
            scrcpyBinaryPath: scrcpyPath,
            force: forceHostRebuild
        ) else {
            log.error("ensureHostApp failed (attempt \(attempt))")
            // Last resort: launch the nested host executable (keeps .app identity),
            // then bare Process only if that also fails.
            if !launchMirrorViaHostExecutable(serial: serial, scrcpyPath: scrcpyPath, args: args, inputMode: inputMode) {
                launchMirrorViaProcess(serial: serial, scrcpyPath: scrcpyPath, args: args, inputMode: inputMode)
            }
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.arguments = args
        config.environment = adbEnv()
        config.activates = true
        config.createsNewApplicationInstance = true
        config.promptsUserIfNeeded = false

        let maxSize = args.firstIndex(of: "--max-size").flatMap { i in args.indices.contains(i + 1) ? args[i + 1] : nil } ?? "?"
        log.info("mirror openApplication attempt=\(attempt) mode=\(String(describing: inputMode)) \(maxSize)p")
        log.info("mirror args: \(args.joined(separator: " "), privacy: .public)")

        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { [weak self] app, error in
            Task { @MainActor in
                guard let self else { return }
                guard self.intendingToRun.contains(serial) else {
                    app?.terminate()
                    return
                }
                if let error {
                    log.error("mirror openApplication failed: \(error.localizedDescription, privacy: .public)")
                    if attempt < 2 {
                        // Force rebuild host (icon/sign/plist) and retry once.
                        self.openMirrorHostApp(
                            serial: serial,
                            scrcpyPath: scrcpyPath,
                            args: args,
                            inputMode: inputMode,
                            forceHostRebuild: true,
                            attempt: attempt + 1
                        )
                        return
                    }
                    if self.launchMirrorViaHostExecutable(
                        serial: serial,
                        scrcpyPath: scrcpyPath,
                        args: args,
                        inputMode: inputMode
                    ) {
                        return
                    }
                    self.launchMirrorViaProcess(
                        serial: serial,
                        scrcpyPath: scrcpyPath,
                        args: args,
                        inputMode: inputMode
                    )
                    return
                }
                if let app {
                    self.markMirrorReady(serial: serial, pid: app.processIdentifier, app: app)
                    app.activate(options: [.activateAllWindows])
                } else {
                    log.error("mirror openApplication returned no app (attempt \(attempt))")
                    if attempt < 2 {
                        self.openMirrorHostApp(
                            serial: serial,
                            scrcpyPath: scrcpyPath,
                            args: args,
                            inputMode: inputMode,
                            forceHostRebuild: true,
                            attempt: attempt + 1
                        )
                        return
                    }
                    if !self.launchMirrorViaHostExecutable(
                        serial: serial,
                        scrcpyPath: scrcpyPath,
                        args: args,
                        inputMode: inputMode
                    ) {
                        self.launchMirrorViaProcess(
                            serial: serial,
                            scrcpyPath: scrcpyPath,
                            args: args,
                            inputMode: inputMode
                        )
                    }
                }
            }
        }
    }

    /// Secondary path: run the nested host-app executable (inside `.app/Contents/MacOS`).
    /// Launch Services still binds the process to the .app → correct Dock name/icon,
    /// and we can pass full ADB/SCRCPY_SERVER_PATH environment (unlike `open`).
    @discardableResult
    private func launchMirrorViaHostExecutable(
        serial: String,
        scrcpyPath: String,
        args: [String],
        inputMode: MirrorInputMode
    ) -> Bool {
        guard let appURL = ensureHostApp(role: .mirror, scrcpyBinaryPath: scrcpyPath, force: true) else {
            return false
        }

        let execName = Self.hostExecutableName(for: .mirror)
        let hostExec = appURL
            .appendingPathComponent("Contents/MacOS/\(execName)", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: hostExec.path) else {
            return false
        }

        let proc = Process()
        proc.executableURL = hostExec
        proc.arguments = args
        proc.environment = adbEnv()
        proc.currentDirectoryURL = appURL
        proc.terminationHandler = { [weak self] p in
            let pid = p.processIdentifier
            Task { @MainActor in
                self?.handleTerminatedPid(pid)
            }
        }

        do {
            try proc.run()
            processes[serial] = proc
            let pid = proc.processIdentifier
            markMirrorReady(
                serial: serial,
                pid: pid,
                app: NSRunningApplication(processIdentifier: pid)
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.intendingToRun.contains(serial) else { return }
                if let app = NSRunningApplication(processIdentifier: pid) {
                    self.mirrorApps[serial] = app
                    app.activate(options: [.activateAllWindows])
                    log.info("mirror host-exec pid=\(pid) name=\(app.localizedName ?? "?", privacy: .public) bid=\(app.bundleIdentifier ?? "nil", privacy: .public)")
                }
            }
            log.info("mirror host-exec launch pid=\(pid) mode=\(String(describing: inputMode))")
            return true
        } catch {
            log.error("host-exec launch failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Absolute last resort: bare scrcpy binary (Dock may show generic "exec").
    /// Surfaces a visible hint so we never silently degrade without the user knowing.
    private func launchMirrorViaProcess(
        serial: String,
        scrcpyPath: String,
        args: [String],
        inputMode: MirrorInputMode
    ) {
        controlHint = String(localized:
            "Mirror is running in compatibility mode (Dock icon may look generic). Quit and restart Mirror if the picture is laggy.")
        log.error("mirror bare-Process fallback — Dock icon may be wrong")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: scrcpyPath)
        proc.arguments = args
        proc.environment = adbEnv()
        proc.terminationHandler = { [weak self] p in
            let pid = p.processIdentifier
            Task { @MainActor in
                self?.handleTerminatedPid(pid)
            }
        }

        do {
            try proc.run()
            processes[serial] = proc
            let pid = proc.processIdentifier
            let app = NSRunningApplication(processIdentifier: pid)
            markMirrorReady(serial: serial, pid: pid, app: app)
            app?.activate(options: [.activateAllWindows])
            log.info("mirror Process fallback pid=\(pid) mode=\(String(describing: inputMode))")
        } catch {
            abortLaunch(serial: serial)
            launchError = "scrcpy launch failed: \(error.localizedDescription)"
            log.error("Process.run failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleTerminatedPid(_ pid: Int32) {
        // Process-based mirror: track by pid map, not only NSRunningApplication.
        let mirrorSerial =
            mirrorPids.first(where: { $0.value == pid })?.key
            ?? mirrorApps.first(where: { $0.value.processIdentifier == pid })?.key
            ?? processes.first(where: { $0.value.processIdentifier == pid })?.key

        if let serial = mirrorSerial {
            let started = launchTime[serial]
            mirrorApps.removeValue(forKey: serial)
            mirrorPids.removeValue(forKey: serial)
            processes.removeValue(forKey: serial)
            runningSerials.remove(serial)
            launchingSerials.remove(serial)
            if launchingSerials.isEmpty { launchStatusText = nil }
            launchTime.removeValue(forKey: serial)
            log.info("mirror exited for \(serial.suffix(8), privacy: .public)")

            // Session `--record` finalizes when scrcpy exits.
            if recordingKinds[serial] == .sessionScrcpy {
                handleRecordingProcessExit(serial: serial, status: 0)
            }

            let stillWanted = intendingToRun.contains(serial)
            intendingToRun.remove(serial)
            // Only auto-restart crash loops (died within a few seconds of start).
            // Do not auto-restart when inject was blocked (user may be in settings).
            if stillWanted, let started, Date().timeIntervalSince(started) < 8 {
                let count = (crashCount[serial] ?? 0) + 1
                crashCount[serial] = count
                if count <= 3 {
                    log.info("mirror crash restart attempt \(count)")
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(min(count, 3)))
                        guard self.intendingToRun.isEmpty || !self.runningSerials.contains(serial) else { return }
                        self.launch(serial: serial, deviceModel: self.deviceModels[serial])
                    }
                } else {
                    crashCount.removeValue(forKey: serial)
                    launchError = String(localized:
                        "scrcpy kept crashing. Check device connection or try another resolution.")
                }
            } else {
                crashCount.removeValue(forKey: serial)
            }
            return
        }

        if let serial = recorderApps.first(where: { $0.value.processIdentifier == pid })?.key {
            handleRecordingProcessExit(serial: serial, status: 0)
        }
    }

    func stop(serial: String) {
        intendingToRun.remove(serial)
        crashCount.removeValue(forKey: serial)
        launchingSerials.remove(serial)
        if launchingSerials.isEmpty { launchStatusText = nil }
        // adb clip: finalize pull first. Session `--record` finalizes on process exit.
        if recordingKinds[serial] == .adb {
            stopRecording(serial: serial)
        }
        if let app = mirrorApps.removeValue(forKey: serial) {
            app.terminate()
        }
        if let proc = processes.removeValue(forKey: serial) {
            proc.terminate()
        }
        mirrorPids.removeValue(forKey: serial)
        runningSerials.remove(serial)
        log.info("scrcpy stop requested for \(serial.suffix(8), privacy: .public)")
    }

    func stopAll() {
        intendingToRun.removeAll()
        crashCount.removeAll()
        launchingSerials.removeAll()
        launchStatusText = nil
        // Finalize recordings before killing mirror hosts.
        for serial in Array(recordingSerials) {
            stopRecording(serial: serial)
        }
        for (_, app) in mirrorApps { app.terminate() }
        mirrorApps.removeAll()
        for (_, app) in recorderApps { app.terminate() }
        recorderApps.removeAll()
        mirrorPids.removeAll()
        for (_, proc) in processes { proc.terminate() }
        processes.removeAll()
        runningSerials.removeAll()
        for (_, proc) in recordingProcesses { proc.interrupt() }
        recordingProcesses.removeAll()
        recordingRemotePaths.removeAll()
        recordingLocalURLs.removeAll()
        recordingSerials.removeAll()
        recordingStartedAt.removeAll()
        recordingHitTimeLimit.removeAll()
        recordingKinds.removeAll()
        sessionRecordURLs.removeAll()
        recordOnLaunch.removeAll()
        recordingFinalizing.removeAll()
    }

    /// Local output path for an in-progress recording (keyed by serial).
    private var recordingLocalURLs: [String: URL] = [:]
    private var recordingFinalizing: Set<String> = []

    // MARK: - Keyboard (Mac ⌘ muscle memory)

    /// UserDefaults key for scrcpy `--keyboard=` mode.
    nonisolated static let keyboardModeKey = "mirror.keyboard"
    /// When true (default on macOS), Super/⌘ is a scrcpy shortcut MOD so
    /// ⌘C/⌘V/⌘X map to device copy/paste/cut shortcuts (not raw Meta).
    nonisolated static let cmdAsShortcutModKey = "mirror.cmd_as_shortcut_mod"

    /// Allowed `--keyboard=` values (scrcpy 2+/3+).
    enum KeyboardMode: String, CaseIterable, Identifiable, Sendable {
        case sdk
        case uhid
        case disabled
        var id: String { rawValue }
        var label: String {
            switch self {
            case .sdk: return String(localized: "System (sdk)")
            case .uhid: return String(localized: "Physical HID (uhid)")
            case .disabled: return String(localized: "Disabled")
            }
        }
    }

    nonisolated static func resolvedKeyboardMode(from defaults: UserDefaults = .standard) -> KeyboardMode {
        let raw = defaults.string(forKey: keyboardModeKey) ?? KeyboardMode.sdk.rawValue
        return KeyboardMode(rawValue: raw) ?? .sdk
    }

    /// scrcpy args for keyboard injection + Mac ⌘ shortcut MOD.
    nonisolated static func keyboardArgs(from defaults: UserDefaults = .standard) -> [String] {
        var args = ["--keyboard=\(resolvedKeyboardMode(from: defaults).rawValue)"]
        // On Mac, keep ⌘ as a scrcpy MOD (with Alt) so MOD+c/v/x hit clipboard
        // shortcuts instead of sending Meta to Android (which apps ignore).
        let cmdAsMod: Bool = {
            if defaults.object(forKey: cmdAsShortcutModKey) == nil { return true }
            return defaults.bool(forKey: cmdAsShortcutModKey)
        }()
        if cmdAsMod {
            args.append(contentsOf: ["--shortcut-mod", "lalt,lsuper"])
        }
        return args
    }

    /// UserDefaults key for scrcpy `--mouse=` mode.
    nonisolated static let mouseModeKey = "mirror.mouse"

    /// Allowed `--mouse=` values (scrcpy 3+/4+).
    enum MouseMode: String, CaseIterable, Identifiable, Sendable {
        case sdk
        case uhid
        case disabled
        var id: String { rawValue }
        var label: String {
            switch self {
            case .sdk: return String(localized: "System (sdk)")
            case .uhid: return String(localized: "Physical HID (uhid)")
            case .disabled: return String(localized: "View only")
            }
        }
    }

    nonisolated static func resolvedMouseMode(from defaults: UserDefaults = .standard) -> MouseMode {
        let raw = defaults.string(forKey: mouseModeKey) ?? MouseMode.sdk.rawValue
        return MouseMode(rawValue: raw) ?? .sdk
    }

    /// Always pass an explicit mouse mode so control is never accidental “disabled”.
    nonisolated static func mouseArgs(from defaults: UserDefaults = .standard) -> [String] {
        ["--mouse=\(resolvedMouseMode(from: defaults).rawValue)"]
    }

    /// Start recording. When a live mirror is already open for this serial, use
    /// `adb shell screenrecord` (works alongside scrcpy). Otherwise fall back to
    /// a headless scrcpy agent host app — a second scrcpy session on the same
    /// device would fight the mirror for the video encoder.
    @discardableResult
    func startRecording(serial: String) -> Bool {
        guard !recordingSerials.contains(serial) else { return false }
        recordingError = nil
        lastRecordingURL = nil

        if runningSerials.contains(serial) {
            return startAdbScreenRecord(serial: serial)
        }
        return startHeadlessScrcpyRecord(serial: serial)
    }

    /// adb screenrecord path — safe while mirror is streaming.
    private func startAdbScreenRecord(serial: String) -> Bool {
        recordingSerials.insert(serial)
        recordingStartedAt[serial] = Date()
        recordingKinds[serial] = .adb
        log.info("recording via adb screenrecord (mirror active)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let started = AdbBridge.shared.startScreenRecord(serial: serial) else {
                Task { @MainActor in
                    guard let self else { return }
                    self.recordingSerials.remove(serial)
                    self.recordingStartedAt.removeValue(forKey: serial)
                    self.recordingKinds.removeValue(forKey: serial)
                    self.recordingError = String(localized: "Could not start recording")
                }
                return
            }
            Task { @MainActor in
                guard let self else { return }
                guard self.recordingSerials.contains(serial) else {
                    // User cancelled before start finished.
                    _ = AdbBridge.shared.finishScreenRecord(
                        serial: serial, process: started.process, remotePath: started.remotePath
                    )
                    return
                }
                self.recordingProcesses[serial] = started.process
                self.recordingRemotePaths[serial] = started.remotePath
            }
        }
        return true
    }

    /// Headless scrcpy recorder via **agent** host app (LSUIElement → no Dock icon).
    /// Only used when no live mirror is open for this serial.
    private func startHeadlessScrcpyRecord(serial: String) -> Bool {
        refreshAvailability()
        guard let scrcpy = findScrcpy(),
              let appURL = ensureHostApp(role: .recorder, scrcpyBinaryPath: scrcpy) else {
            recordingError = String(localized: "Could not start recording")
            return false
        }

        // Record into Application Support first so the agent app never touches
        // Downloads (avoids a TCC “access files” prompt every stop).
        // Main app then moves the file into Downloads after finalize.
        let staging = Self.recordingStagingDirectory()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let url = staging.appendingPathComponent("DroidMate-\(fmt.string(from: Date())).mp4")
        try? FileManager.default.removeItem(at: url)

        let args = [
            "--serial", serial,
            "--no-playback",
            "--no-window",
            "--no-audio",
            "--max-size", "1920",
            "--video-bit-rate", "8M",
            "--record", url.path,
        ]

        recordingLocalURLs[serial] = url
        recordingSerials.insert(serial)
        recordingStartedAt[serial] = Date()
        recordingKinds[serial] = .headlessScrcpy

        let config = NSWorkspace.OpenConfiguration()
        config.arguments = args
        config.environment = adbEnv()
        config.activates = false
        config.createsNewApplicationInstance = true
        config.promptsUserIfNeeded = false

        log.info("openApplication recorder → \(url.lastPathComponent, privacy: .public)")
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { [weak self] app, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.recordingSerials.remove(serial)
                    self.recordingStartedAt.removeValue(forKey: serial)
                    self.recordingKinds.removeValue(forKey: serial)
                    self.recordingLocalURLs.removeValue(forKey: serial)
                    self.recordingError = String(localized: "Could not start recording")
                    log.error("recorder open failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
                if let app {
                    self.recorderApps[serial] = app
                }
            }
        }
        return true
    }

    /// Stop recording: finalize adb screenrecord or scrcpy agent / session.
    func stopRecording(serial: String) {
        // Session `--record` ends only when the mirror process exits.
        if recordingKinds[serial] == .sessionScrcpy {
            controlHint = String(localized: "Stopping mirror to save the recording…")
            stop(serial: serial)
            return
        }

        guard !recordingFinalizing.contains(serial) else { return }
        recordingFinalizing.insert(serial)

        // adb screenrecord path (used when mirror is live).
        if let proc = recordingProcesses[serial],
           let remote = recordingRemotePaths[serial] {
            recordingProcesses.removeValue(forKey: serial)
            recordingRemotePaths.removeValue(forKey: serial)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let url = AdbBridge.shared.finishScreenRecord(
                    serial: serial, process: proc, remotePath: remote
                )
                Task { @MainActor in
                    guard let self else { return }
                    let hitLimit = self.recordingHitTimeLimit.remove(serial) != nil
                    self.recordingFinalizing.remove(serial)
                    self.recordingSerials.remove(serial)
                    self.recordingStartedAt.removeValue(forKey: serial)
                    self.recordingKinds.removeValue(forKey: serial)
                    if let url {
                        self.lastRecordingURL = url
                        self.recordingError = nil
                        if hitLimit {
                            // Android screenrecord hard cap — not an artificial product limit.
                            self.controlHint = String(localized:
                                "Live clip stopped at Android’s 3-minute screenrecord limit and was saved. For longer video, use Start Mirror & Record.")
                        }
                        log.info("adb recording saved \(url.lastPathComponent, privacy: .public) limit=\(hitLimit)")
                        NSSound(named: "Glass")?.play()
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        self.recordingError = String(localized: "Recording failed to save")
                        NSSound.beep()
                    }
                }
            }
            return
        }

        if let app = recorderApps[serial] {
            // Prefer graceful terminate (scrcpy flushes recording on clean exit).
            app.terminate()
            // Fallback finalize after a short wait if still alive.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, self.recordingSerials.contains(serial) else { return }
                if let app = self.recorderApps[serial], !app.isTerminated {
                    app.forceTerminate()
                }
                self.handleRecordingProcessExit(serial: serial, status: 0)
            }
            return
        }
        if let p = recordingProcesses[serial] {
            p.interrupt()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let deadline = Date().addingTimeInterval(6)
                while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if p.isRunning { p.terminate() }
                p.waitUntilExit()
                Thread.sleep(forTimeInterval: 0.2)
                Task { @MainActor in
                    self?.handleRecordingProcessExit(serial: serial, status: p.terminationStatus)
                }
            }
            return
        }
        recordingFinalizing.remove(serial)
        recordingSerials.remove(serial)
        recordingStartedAt.removeValue(forKey: serial)
        recordingLocalURLs.removeValue(forKey: serial)
        recordingRemotePaths.removeValue(forKey: serial)
    }

    /// Elapsed recording time for UI (`m:ss` / `h:mm:ss`). Nil if not recording.
    func recordingElapsedString(for serial: String, now: Date = Date()) -> String? {
        guard recordingSerials.contains(serial),
              let start = recordingStartedAt[serial] else { return nil }
        return Self.formatRecordingDuration(now.timeIntervalSince(start))
    }

    /// Whether this recording uses adb screenrecord (3-minute hard cap).
    func isAdbCappedRecording(serial: String) -> Bool {
        recordingKinds[serial] == .adb
    }

    /// Same scrcpy process `--record` (stops when mirror stops).
    func isSessionRecording(serial: String) -> Bool {
        recordingKinds[serial] == .sessionScrcpy
    }

    /// Remaining seconds before adb `screenrecord` hard limit.
    func recordingRemainingSeconds(for serial: String, now: Date = Date()) -> Int? {
        guard isAdbCappedRecording(serial: serial),
              let start = recordingStartedAt[serial] else { return nil }
        let left = Self.adbScreenRecordTimeLimitSeconds - now.timeIntervalSince(start)
        return max(0, Int(left.rounded(.down)))
    }

    /// If adb recording hit the 180s cap, stop and mark for UI messaging.
    /// Returns true when a stop was initiated.
    @discardableResult
    func stopRecordingIfTimeLimitReached(serial: String, now: Date = Date()) -> Bool {
        guard isAdbCappedRecording(serial: serial),
              let start = recordingStartedAt[serial],
              now.timeIntervalSince(start) >= Self.adbScreenRecordTimeLimitSeconds
        else { return false }
        recordingHitTimeLimit.insert(serial)
        stopRecording(serial: serial)
        return true
    }

    /// Whether the last stop for this serial was due to the 3-minute adb limit.
    func didRecordingHitTimeLimit(serial: String) -> Bool {
        recordingHitTimeLimit.contains(serial)
    }

    nonisolated static func formatRecordingDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// Human label for the adb screenrecord cap (e.g. "3:00").
    nonisolated static var adbScreenRecordTimeLimitLabel: String {
        formatRecordingDuration(adbScreenRecordTimeLimitSeconds)
    }

    /// Staging dir for scrcpy agent (no Downloads TCC).
    private static func recordingStagingDirectory() -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DroidMate/Recordings", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func handleRecordingProcessExit(serial: String, status: Int32) {
        defer {
            recordingFinalizing.remove(serial)
            recordingProcesses.removeValue(forKey: serial)
            recorderApps.removeValue(forKey: serial)
            recordingSerials.remove(serial)
            recordingStartedAt.removeValue(forKey: serial)
            recordingKinds.removeValue(forKey: serial)
            sessionRecordURLs.removeValue(forKey: serial)
        }
        // Avoid double-finalize
        guard recordingLocalURLs[serial] != nil || recordingSerials.contains(serial) else { return }
        let staged = recordingLocalURLs.removeValue(forKey: serial)
        guard let staged else { return }

        // Give scrcpy a moment to flush the file after terminate.
        let size: Int64 = {
            for _ in 0..<10 {
                let s = (try? FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?
                    .int64Value ?? 0
                if s > 8192 { return s }
                Thread.sleep(forTimeInterval: 0.15)
            }
            return (try? FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?
                .int64Value ?? 0
        }()

        guard size > 8192, FileManager.default.fileExists(atPath: staged.path) else {
            try? FileManager.default.removeItem(at: staged)
            recordingError = String(localized: "Recording failed to save")
            NSSound.beep()
            log.error("recording invalid size=\(size) status=\(status)")
            return
        }

        // Move into Downloads from the *main* app process (already trusted by TCC).
        let destDir = AdbBridge.mediaSaveDirectory()
        var dest = destDir.appendingPathComponent(staged.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            dest = destDir.appendingPathComponent("DroidMate-\(fmt.string(from: Date())).mp4")
        }
        do {
            try FileManager.default.moveItem(at: staged, to: dest)
            lastRecordingURL = dest
            recordingError = nil
            log.info("recording saved \(dest.lastPathComponent, privacy: .public) (\(size) bytes)")
            NSSound(named: "Glass")?.play()
            // Reveal in Finder so the user doesn't hunt Downloads.
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            // Fall back to leaving the staged file (still a valid recording).
            lastRecordingURL = staged
            recordingError = nil
            log.error("move to Downloads failed, kept staged: \(error.localizedDescription, privacy: .public)")
            NSSound(named: "Glass")?.play()
            NSWorkspace.shared.activateFileViewerSelecting([staged])
        }
    }

    /// Open the last recording in Finder (no-op if none).
    func revealLastRecording() {
        guard let url = lastRecordingURL else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    func clearLaunchError() { launchError = nil }

    var isScrcpyAvailable: Bool { findScrcpy() != nil }

    func sendKey(serial: String, keycode: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let adb = AdbLocator.shared.findAdb() else {
                Task { @MainActor in
                    self?.controlHint = String(localized: "adb not found — cannot send keys")
                }
                return
            }
            do {
                _ = try AdbRunner.run(
                    adb,
                    args: ["-s", serial, "shell", "input", "keyevent", keycode]
                )
            } catch {
                let msg = error.localizedDescription
                log.error("sendKey \(keycode, privacy: .public) failed: \(msg, privacy: .public)")
                Task { @MainActor in
                    if msg.localizedCaseInsensitiveContains("SecurityException")
                        || msg.localizedCaseInsensitiveContains("INJECT_EVENTS")
                        || msg.localizedCaseInsensitiveContains("Injecting input") {
                        self?.controlHint = String(localized:
                            "Phone blocked key injection. Enable Developer options → USB debugging (Security settings), then reconnect USB and restart mirror. (Xiaomi/HyperOS)")
                    } else {
                        self?.controlHint = String(localized: "Key send failed — \(msg)")
                    }
                }
            }
        }
    }

    func clearControlHint() { controlHint = nil }
}
