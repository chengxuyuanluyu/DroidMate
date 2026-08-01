import Foundation
import DroidMateWire

/// Thin MCP-facing adb helpers on top of shared DroidMateWire types.
enum Adb {
    static func findAdb() -> String? {
        AdbLocator.shared.findAdb()
    }

    static func listDevicesFormatted() -> String {
        guard let raw = try? execString(["devices", "-l"]) else {
            return "adb not available"
        }
        let lines = raw.split(separator: "\n").map(String.init).filter {
            !$0.isEmpty && !$0.hasPrefix("List of devices")
        }
        return lines.isEmpty ? "no devices" : lines.joined(separator: "\n")
    }

    @discardableResult
    static func execString(_ args: [String], serial: String? = nil) throws -> String {
        let data = try execData(args, serial: serial)
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func execData(_ args: [String], serial: String? = nil) throws -> Data {
        guard let adb = findAdb() else { throw AdbError.notFound }
        var full = args
        if let serial, !serial.isEmpty {
            full = ["-s", serial] + args
        }
        return try AdbRunner.runData(adb, args: full)
    }
}
