import Darwin
import Foundation

public enum AdbRunner {
    @discardableResult
    public static func run(
        _ executable: String,
        args: [String],
        timeout: TimeInterval? = nil
    ) throws -> String {
        String(decoding: try runData(executable, args: args, timeout: timeout), as: UTF8.self)
    }

    public static func runData(
        _ executable: String,
        args: [String],
        timeout: TimeInterval? = nil
    ) throws -> Data {
        try Task.checkCancellation()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe
        try p.run()

        let stdout = DataCapture()
        let stderr = DataCapture()
        let drains = DispatchGroup()
        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            drains.leave()
        }
        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            drains.leave()
        }

        let deadline = timeout.map { Date().addingTimeInterval($0) }
        var didCancel = false
        var didTimeOut = false
        // Block on a background thread instead of spinning: waitUntilExit
        // parks the kernel, so a 10-30s adb call no longer burns a CPU core.
        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            p.waitUntilExit()
            exitSignal.signal()
        }
        while exitSignal.wait(timeout: .now() + 0.05) == .timedOut {
            if Task.isCancelled {
                didCancel = true
                break
            }
            if let deadline, Date() >= deadline {
                didTimeOut = true
                break
            }
        }
        if p.isRunning, didCancel || didTimeOut {
            p.terminate()
            let killDeadline = Date().addingTimeInterval(0.5)
            while p.isRunning, Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if p.isRunning {
                Darwin.kill(p.processIdentifier, SIGKILL)
            }
            // The loop above exited via `.timedOut` (deadline/cancel) so the
            // background waiter's signal is still pending — consume it here.
            // On the normal-exit path the loop already consumed the signal.
            exitSignal.wait()
        }
        drains.wait()

        if didCancel {
            throw CancellationError()
        }
        // Cancellation may arrive after the child exits (or while pipe drains
        // finish). It still wins over a seemingly successful command result.
        try Task.checkCancellation()
        if didTimeOut {
            throw AdbError.timedOut(seconds: timeout ?? 0)
        }
        guard p.terminationStatus == 0 else {
            let failureOutput = stderr.data.isEmpty ? stdout.data : stderr.data
            throw AdbError.commandFailed(
                status: p.terminationStatus,
                stderr: String(decoding: failureOutput, as: UTF8.self)
            )
        }
        return stdout.data
    }

    public static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum AdbError: LocalizedError, Sendable {
    case notFound
    case serverJarNotFound
    case commandFailed(status: Int32, stderr: String)
    case timedOut(seconds: TimeInterval)
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
        case .timedOut(let seconds):
            return "Command timed out after \(seconds) seconds."
        case .wifiPairFailed(let message), .wifiConnectFailed(let message), .failed(let message):
            return message
        }
    }
}

private final class DataCapture: @unchecked Sendable {
    var data = Data()
}
