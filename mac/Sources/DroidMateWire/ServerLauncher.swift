import Foundation

/// Pushes and starts DroidMate Server on device (app_process + jar).
public final class ServerLauncher: @unchecked Sendable {
    public static let shared = ServerLauncher()

    public init() {}

    public func findServerJar() -> URL? {
        let home = NSHomeDirectory()
        let candidates: [String?] = [
            // Packaged app + repo-vendored jar (device server ships as binary in Resources).
            Bundle.main.url(forResource: "droidmate-server", withExtension: "jar")?.path,
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/droidmate-server.jar").path,
            "\(home)/Developer/DroidMate/mac/Resources/droidmate-server.jar",
            // Dev: next to SPM product when running from .build/
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("droidmate-server.jar").path,
        ]
        for path in candidates.compactMap({ $0 }) {
            let expanded = path.hasPrefix("~")
                ? URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
                : URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: expanded.path) {
                return expanded
            }
        }
        return nil
    }

    public func launchServer(
        serial: String,
        localPort: UInt16,
        remotePort: UInt16 = PortForwarder.remotePort
    ) throws {
        guard let adb = AdbLocator.shared.findAdb() else { throw AdbError.notFound }
        guard let jar = findServerJar() else { throw AdbError.serverJarNotFound }

        let remote = "/data/local/tmp/droidmate-server.jar"
        _ = try AdbRunner.run(adb, args: ["-s", serial, "push", jar.path, remote])
        _ = try AdbRunner.run(
            adb,
            args: ["-s", serial, "forward", "tcp:\(localPort)", "tcp:\(remotePort)"]
        )

        _ = try? AdbRunner.run(adb, args: [
            "-s", serial, "shell",
            "pkill -f com.droidmate.server.ServerMain 2>/dev/null; true",
        ])

        _ = try AdbRunner.run(adb, args: [
            "-s", serial, "shell",
            "CLASSPATH=\(remote) app_process / com.droidmate.server.ServerMain >/dev/null 2>&1 </dev/null &",
        ])
    }
}
