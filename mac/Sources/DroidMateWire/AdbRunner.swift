import Foundation

public enum AdbRunner {
    @discardableResult
    public static func run(_ executable: String, args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard p.terminationStatus == 0 else {
            throw AdbError.commandFailed(
                status: p.terminationStatus,
                stderr: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    public static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum AdbError: LocalizedError, Sendable {
    case notFound
    case serverJarNotFound
    case commandFailed(status: Int32, stderr: String)
    case wifiPairFailed(message: String)
    case wifiConnectFailed(message: String)
    /// Generic failure message (MCP-style).
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "adb not found. Install Android platform-tools or use DroidMate.app bundled adb."
        case .serverJarNotFound:
            return "droidmate-server.jar not found. Expected under the app Resources or mac/Resources/."
        case .commandFailed(let status, let stderr):
            return "adb failed (\(status)): \(stderr)"
        case .wifiPairFailed(let message), .wifiConnectFailed(let message), .failed(let message):
            return message
        }
    }
}
