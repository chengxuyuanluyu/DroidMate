import Foundation

/// Package management via adb (list / launch / stop / install / uninstall).
final class AdbAppManager: @unchecked Sendable {
    static let shared = AdbAppManager()

    struct AppInfo: Identifiable, Hashable, Sendable {
        var id: String { package }
        let package: String
        /// Display name (application label when resolved, else last path segment).
        let label: String
        /// From `pm path` when resolved (optional).
        let apkPath: String?
    }

    enum Scope: String, Sendable {
        /// Third-party only (`pm list packages -3`).
        case thirdParty
        /// All packages including system (`pm list packages`).
        case all
    }

    // MARK: - Label cache (package → application label)

    private let labelCacheLock = NSLock()
    private var memoryLabels: [String: String] = [:]
    private let labelCacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DroidMate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app-labels.json")
    }()

    private init() {
        loadLabelCache()
    }

    // MARK: - List

    func listPackages(serial: String, scope: Scope = .thirdParty, resolveLabels: Bool = false) -> [AppInfo] {
        guard let adb = AdbLocator.shared.findAdb() else { return [] }
        var args = ["-s", serial, "shell", "pm", "list", "packages"]
        if scope == .thirdParty { args.append("-3") }
        guard let out = try? AdbRunner.run(adb, args: args) else { return [] }
        var apps = out.split(separator: "\n").compactMap { line -> AppInfo? in
            let pkg = line.trimmingCharacters(in: .whitespaces)
            guard pkg.hasPrefix("package:") else { return nil }
            let name = String(pkg.dropFirst("package:".count))
            guard !name.isEmpty else { return nil }
            let fallback = name.split(separator: ".").last.map(String.init) ?? name
            let label = cachedLabel(for: name) ?? fallback
            return AppInfo(package: name, label: label, apkPath: nil)
        }
        if resolveLabels {
            apps = apps.map { app in
                if let resolved = resolveLabel(serial: serial, package: app.package) {
                    return AppInfo(package: app.package, label: resolved, apkPath: app.apkPath)
                }
                return app
            }
            saveLabelCache()
        }
        return apps
    }

    /// Resolve a single package’s application label (cached). Slow path uses dumpsys.
    func resolveLabel(serial: String, package: String) -> String? {
        if let hit = cachedLabel(for: package) { return hit }
        guard let adb = AdbLocator.shared.findAdb() else { return nil }
        // dumpsys is heavy but works without aapt; bound output with head.
        let shell = "dumpsys package \(AdbRunner.shellEscape(package)) 2>/dev/null | grep -E 'applicationLabel|application-label|nonLocalizedLabel' | head -5"
        guard let out = try? AdbRunner.run(adb, args: ["-s", serial, "shell", shell]) else { return nil }
        if let label = Self.parseApplicationLabel(from: out), !label.isEmpty {
            storeLabel(label, for: package)
            return label
        }
        return nil
    }

    /// Resolve labels for packages that still show a heuristic last-segment name.
    /// Bounded concurrency; mutates cache. Call off the main thread.
    func enrichLabels(serial: String, packages: [String], maxResolve: Int = 80) {
        let fallbackish = packages.filter { pkg in
            let last = pkg.split(separator: ".").last.map(String.init) ?? pkg
            let cached = cachedLabel(for: pkg)
            return cached == nil || cached == last
        }
        let batch = Array(fallbackish.prefix(maxResolve))
        // Serial dumpsys is safer than hammering the device; still OK for ~50 apps.
        for pkg in batch {
            _ = resolveLabel(serial: serial, package: pkg)
        }
        saveLabelCache()
    }

    func labelForPackage(_ package: String) -> String? {
        cachedLabel(for: package)
    }

    // MARK: - Launch / stop

    /// Launch the default launcher activity for `package`.
    func launchPackage(serial: String, package: String) throws {
        guard let adb = AdbLocator.shared.findAdb() else { throw AdbError.notFound }
        // monkey is the most reliable one-liner for “open app” without resolving the activity.
        let cmd = "monkey -p \(AdbRunner.shellEscape(package)) -c android.intent.category.LAUNCHER 1"
        _ = try AdbRunner.run(adb, args: ["-s", serial, "shell", cmd])
    }

    func forceStopPackage(serial: String, package: String) throws {
        guard let adb = AdbLocator.shared.findAdb() else { throw AdbError.notFound }
        _ = try AdbRunner.run(adb, args: ["-s", serial, "shell", "am", "force-stop", package])
    }

    func clearPackageData(serial: String, package: String) throws {
        guard let adb = AdbLocator.shared.findAdb() else { throw AdbError.notFound }
        _ = try AdbRunner.run(adb, args: ["-s", serial, "shell", "pm", "clear", package])
    }

    // MARK: - Install / uninstall

    func uninstallPackage(serial: String, package: String) throws {
        guard let adb = AdbLocator.shared.findAdb() else { throw AdbError.notFound }
        _ = try AdbRunner.run(adb, args: ["-s", serial, "uninstall", package])
    }

    /// Install (replace) an APK. Returns adb stdout on success.
    @discardableResult
    func installApk(serial: String, localPath: String) throws -> String {
        guard let adb = AdbLocator.shared.findAdb() else { throw AdbError.notFound }
        return try AdbRunner.run(adb, args: ["-s", serial, "install", "-r", localPath])
    }

    /// Copy package name of the foreground app (best-effort via dumpsys).
    func foregroundPackage(serial: String) -> String? {
        guard let adb = AdbLocator.shared.findAdb(),
              let out = try? AdbRunner.run(adb, args: [
                  "-s", serial, "shell",
                  "dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity' | head -1",
              ]) else { return nil }
        let pattern = try? NSRegularExpression(pattern: #"([a-zA-Z0-9_.]+)/[a-zA-Z0-9_.$]+"#)
        let range = NSRange(out.startIndex..<out.endIndex, in: out)
        guard let match = pattern?.firstMatch(in: out, range: range),
              let r = Range(match.range(at: 1), in: out) else { return nil }
        return String(out[r])
    }

    // MARK: - Label parse / cache

    static func parseApplicationLabel(from dumpsysSnippet: String) -> String? {
        // applicationLabel=WeChat
        // application-label:'WeChat'
        // application-label-zh-CN:'微信'
        // nonLocalizedLabel=Settings
        let patterns = [
            #"applicationLabel=([^\n\r]+)"#,
            #"application-label(?:-[a-zA-Z0-9-]+)?:'([^']+)'"#,
            #"application-label(?:-[a-zA-Z0-9-]+)?=\"([^\"]+)\""#,
            #"nonLocalizedLabel=([^\n\r]+)"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let range = NSRange(dumpsysSnippet.startIndex..<dumpsysSnippet.endIndex, in: dumpsysSnippet)
            if let m = re.firstMatch(in: dumpsysSnippet, range: range),
               let r = Range(m.range(at: 1), in: dumpsysSnippet) {
                let s = String(dumpsysSnippet[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { return s }
            }
        }
        return nil
    }

    private func cachedLabel(for package: String) -> String? {
        labelCacheLock.lock()
        defer { labelCacheLock.unlock() }
        return memoryLabels[package]
    }

    private func storeLabel(_ label: String, for package: String) {
        labelCacheLock.lock()
        memoryLabels[package] = label
        labelCacheLock.unlock()
    }

    private func loadLabelCache() {
        guard let data = try? Data(contentsOf: labelCacheURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        labelCacheLock.lock()
        memoryLabels = dict
        labelCacheLock.unlock()
    }

    private func saveLabelCache() {
        labelCacheLock.lock()
        let snap = memoryLabels
        labelCacheLock.unlock()
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: labelCacheURL, options: .atomic)
    }
}
