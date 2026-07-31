import AppKit
import Foundation

/// Builds a plain-text diagnostic report for support / issue filings.
enum DiagnosticsExporter {

    /// Writes a report to a temp file and reveals it in Finder. Returns the path.
    @discardableResult
    static func exportAndReveal() -> URL? {
        let text = buildReport()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "DroidMate-diagnostics-\(formatter.string(from: Date())).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return url
        } catch {
            return nil
        }
    }

    static func buildReport() -> String {
        var lines: [String] = []
        lines.append("DroidMate Diagnostics")
        lines.append(String(repeating: "=", count: 40))
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        // App
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let bid = Bundle.main.bundleIdentifier ?? "?"
        lines.append("## App")
        lines.append("Version: \(short) (\(build))")
        lines.append("Bundle ID: \(bid)")
        lines.append("Path: \(Bundle.main.bundlePath)")
        lines.append("")

        // System
        let os = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("## System")
        lines.append("macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        lines.append("Arch: \(machineArch())")
        lines.append("Host: \(ProcessInfo.processInfo.hostName)")
        lines.append("")

        // adb
        lines.append("## adb")
        if let adb = AdbLocator.shared.findAdb() {
            lines.append("Path: \(adb)")
            lines.append(shellOut("/bin/zsh", ["-lc", "\"\(adb)\" version 2>&1"]))
            lines.append("")
            lines.append("Devices:")
            lines.append(shellOut("/bin/zsh", ["-lc", "\"\(adb)\" devices -l 2>&1"]))
        } else {
            lines.append("Path: (not found)")
        }
        lines.append("")

        // scrcpy
        lines.append("## scrcpy")
        let scrcpy = findScrcpyPath()
        if let scrcpy {
            lines.append("Path: \(scrcpy)")
            lines.append(shellOut("/bin/zsh", ["-lc", "\"\(scrcpy)\" --version 2>&1"]))
        } else {
            lines.append("Path: (not found)")
            lines.append("Install: brew install scrcpy")
        }
        lines.append("")

        // Bundled server jar (Data Channel)
        lines.append("## DroidMate Server")
        let jarCandidates = [
            Bundle.main.bundlePath + "/Contents/Resources/droidmate-server.jar",
            Bundle.main.resourcePath.map { $0 + "/droidmate-server.jar" },
        ].compactMap { $0 }
        var jarFound = false
        for path in jarCandidates {
            if FileManager.default.fileExists(atPath: path) {
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
                lines.append("JAR: \(path)")
                lines.append("Size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                jarFound = true
                break
            }
        }
        if !jarFound {
            lines.append("JAR: (not found in app bundle — reconnect will fail to push server)")
        }
        lines.append("")

        // Download destination
        lines.append("## Downloads")
        if let last = UserDefaults.standard.string(forKey: "lastDownloadDir"), !last.isEmpty {
            lines.append("lastDownloadDir: \(last)")
            lines.append("exists: \(FileManager.default.fileExists(atPath: last))")
        } else {
            let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
            lines.append("lastDownloadDir: (default) \(dl)")
        }
        lines.append("")

        // Preferences (non-secret)
        lines.append("## Preferences")
        let defaults = UserDefaults.standard
        let keys = [
            "mirror.max_size", "mirror.bitrate", "mirror.fps",
            "mirror.keyboard", "mirror.mouse", "mirror.cmd_as_shortcut_mod",
            "audio.enabled", "ui.show_stats", "ui.always_on_top", "ui.viewMode",
            "transfer.auto_retry", "transfer.auto_show_queue", "cache.limit_mb",
            "clipboard.mac_to_android", "clipboard.android_to_mac",
            "notifications.mirror_android",
            "onboarding.completed", "launchSplash.completed",
            "ui.last_seen_whats_new_version",
            "lastDownloadDir",
        ]
        for key in keys {
            if let v = defaults.object(forKey: key) {
                lines.append("\(key) = \(v)")
            } else {
                lines.append("\(key) = (default)")
            }
        }
        lines.append("")
        lines.append("## Notes")
        lines.append("- No device file contents or clipboard data are included.")
        lines.append("- Attach this file when reporting connection or transfer issues.")
        lines.append("- Protocol: DIR_ENTRY includes exists/is_dir; FS mutations on Data Channel.")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func machineArch() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingCString: $0) ?? "?"
            }
        }
    }

    private static func findScrcpyPath() -> String? {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DroidMate/scrcpy").path
        if fm.isExecutableFile(atPath: support) { return support }

        let bundleCandidates = [
            Bundle.main.bundlePath + "/Contents/Resources/Bin/scrcpy",
        ]
        for path in bundleCandidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        let candidates = [
            "/opt/homebrew/bin/scrcpy",
            "/usr/local/bin/scrcpy",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        let which = shellOut("/usr/bin/which", ["scrcpy"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !which.isEmpty, fm.isExecutableFile(atPath: which) {
            return which
        }
        return nil
    }

    private static func shellOut(_ launchPath: String, _ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return "(failed: \(error.localizedDescription))"
        }
    }
}
