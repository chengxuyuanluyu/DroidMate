import Foundation

/// Locates an `adb` binary for both the Mac app and MCP.
public final class AdbLocator: @unchecked Sendable {
    public static let shared = AdbLocator()

    public init() {}

    public func findAdb() -> String? {
        // Explicit override for agents / CI.
        if let env = ProcessInfo.processInfo.environment["DROIDMATE_ADB"], !env.isEmpty,
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }

        let home = NSHomeDirectory()
        var candidates: [String] = []

        // Relative to this process (MCP binary or app MacOS/).
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let exeDir = exe.deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent("adb").path)
        candidates.append(exeDir.appendingPathComponent("Bin/adb").path)
        candidates.append(
            exeDir.deletingLastPathComponent()
                .appendingPathComponent("Resources/Bin/adb").path
        )

        candidates.append(contentsOf: [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Bin/adb").path,
            "/Applications/DroidMate.app/Contents/Resources/Bin/adb",
            "\(home)/Applications/DroidMate.app/Contents/Resources/Bin/adb",
            "\(home)/Developer/DroidMate/mac/Sources/DroidMate/Bin/adb",
            "\(home)/Developer/DroidMate/mac/Resources/Bin/adb",
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/usr/bin/adb",
        ])

        let fm = FileManager.default
        for path in candidates {
            if fm.isExecutableFile(atPath: path) { return path }
        }

        // App-support cache (populated from bundled adb on first app launch).
        let cacheDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DroidMate", isDirectory: true)
        let cachedAdb = cacheDir.appendingPathComponent("adb")
        if fm.isExecutableFile(atPath: cachedAdb.path) {
            return cachedAdb.path
        }

        // Copy from known bundle locations into cache when possible.
        if let bundled = bundledAdbUrl() {
            try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try? fm.removeItem(at: cachedAdb)
            do {
                try fm.copyItem(at: bundled, to: cachedAdb)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cachedAdb.path)
                if fm.isExecutableFile(atPath: cachedAdb.path) { return cachedAdb.path }
            } catch {}
        }

        // which adb
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["adb"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let out, !out.isEmpty, fm.isExecutableFile(atPath: out) { return out }
        return nil
    }

    private func bundledAdbUrl() -> URL? {
        let fm = FileManager.default
        let urls: [URL?] = [
            Bundle.main.url(forResource: "adb", withExtension: nil, subdirectory: "Bin"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Bin/adb"),
        ]
        for u in urls {
            if let u, fm.isExecutableFile(atPath: u.path) { return u }
        }
        let home = NSHomeDirectory()
        let dev = URL(fileURLWithPath: "\(home)/Developer/DroidMate/mac/Sources/DroidMate/Bin/adb")
        if fm.isExecutableFile(atPath: dev.path) { return dev }
        return nil
    }

    public func findBrew() -> String? {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    public func installAdb() throws {
        guard let brew = findBrew() else { throw AdbError.notFound }
        _ = try AdbRunner.run(brew, args: ["install", "android-platform-tools"])
    }
}
