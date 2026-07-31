import Foundation

public final class PortForwarder: @unchecked Sendable {
    public static let shared = PortForwarder()

    public static let remotePort: UInt16 = 28042

    public init() {}

    public func forward(
        serial: String,
        localPort: UInt16,
        remotePort: UInt16 = PortForwarder.remotePort
    ) throws {
        guard let adb = AdbLocator.shared.findAdb() else { throw AdbError.notFound }
        _ = try AdbRunner.run(
            adb,
            args: ["-s", serial, "forward", "tcp:\(localPort)", "tcp:\(remotePort)"]
        )
    }

    public func unforward(serial: String, localPort: UInt16) throws {
        guard let adb = AdbLocator.shared.findAdb() else { throw AdbError.notFound }
        _ = try AdbRunner.run(adb, args: ["-s", serial, "forward", "--remove", "tcp:\(localPort)"])
    }
}
