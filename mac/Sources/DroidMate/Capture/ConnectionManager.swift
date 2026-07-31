import Foundation
import SwiftUI

/// Owns the live `[DeviceSession]` pool and tracks which device is active.
///
/// Single-device flow is just the n=1 case: one engine in the array,
/// `activeDeviceId` pointing at it. The sidebar lists every connected
/// device; clicking a row switches `activeDeviceId`, which the file browser
/// and mirror window observe via `activeEngine`.
///
/// Port allocation: each device gets its own Mac-side TCP port starting at
/// 28050, all forwarded to the Android server's fixed 28042. This keeps the
/// wire protocol and Android side untouched while letting multiple devices
/// stream concurrently.
@MainActor
final class ConnectionManager: ObservableObject {

    @Published private(set) var engines: [DeviceSession] = []
    @Published var activeDeviceId: String?

    /// First Mac-side local port to hand out. Each new device gets the next
    /// one. The Android server always listens on 28042; we forward from
    /// localPort → 28042 per device.
    private var nextLocalPort: UInt16 = 28050

    /// The engine bound to the currently-active device, or the only engine
    /// if no explicit active id is set. nil when no devices are connected.
    var activeEngine: DeviceSession? {
        if let id = activeDeviceId,
           let engine = engines.first(where: { $0.deviceSerial == id }) {
            return engine
        }
        return engines.first
    }

    /// Convenience: active device has completed HELLO and is ready for file ops.
    var isConnected: Bool {
        activeEngine?.isSessionReady ?? false
    }

    /// At least one device session is in the pool (may still be connecting).
    var hasSession: Bool { !engines.isEmpty }

    /// Serials the user explicitly disconnected. ConnectionView must not
    /// auto-connect these while they remain visible in `adb devices`
    /// (wireless adb stays online after we tear down the DroidMate session).
    /// Cleared when the user manually connects again, or when the serial
    /// disappears from adb (true unplug / `adb disconnect`).
    private(set) var autoConnectSuppressed: Set<String> = []

    /// Adds a new device: allocates a port, launches the Android server,
    /// creates a DeviceSession, and starts it. If this is the first device,
    /// it becomes active.
    func addDevice(serial: String) async throws {
        // Manual (or intentional) connect — allow future auto-connect again.
        autoConnectSuppressed.remove(serial)

        guard !engines.contains(where: { $0.deviceSerial == serial }) else {
            // Already connected — just switch to it.
            activeDeviceId = serial
            return
        }

        let port = nextLocalPort
        nextLocalPort &+= 1

        try ServerLauncher.shared.launchServer(serial: serial, localPort: port)
        // Give the server a moment to bind before we connect.
        try? await Task.sleep(for: .seconds(1))

        let engine = DeviceSession(deviceSerial: serial, port: port)
        engine.onNeedsRecovery = { [weak self] in
            guard let self else { return }
            Task { await self.recover(serial: serial) }
        }
        engines.append(engine)
        engine.start()
        // Always switch to the device we just connected (incl. "Add Device" flow).
        activeDeviceId = serial
    }

    func switchTo(_ serial: String) {
        guard engines.contains(where: { $0.deviceSerial == serial }) else { return }
        activeDeviceId = serial
    }

    /// Soft reconnect: re-open the local TCP socket only.
    func reconnect(_ serial: String) {
        guard let engine = engines.first(where: { $0.deviceSerial == serial }) else { return }
        engine.transport.reconnect()
    }

    /// Hard recover: re-assert wireless adb if needed, re-launch the on-device
    /// server, re-forward the port, then reconnect the data channel. Used when
    /// the socket fails for longer than a blip (server died, forward dropped).
    func recover(serial: String) async {
        guard let engine = engines.first(where: { $0.deviceSerial == serial }) else { return }

        // Wireless endpoint may have dropped from adb while the Mac session stayed open.
        if serial.contains(":"), let ep = AdbBridge.WifiEndpoint.parse(serial) {
            engine.markRecovering(detail: String(localized: "Re-establishing wireless adb…"))
            do {
                _ = try AdbBridge.shared.connectWifi(ep)
            } catch {
                engine.markRecovering(detail: String(localized: "Wireless adb reconnect failed — trying server relaunch…"))
            }
            try? await Task.sleep(for: .milliseconds(400))
        } else {
            engine.markRecovering(detail: String(localized: "Relaunching device server…"))
        }

        let present = (try? AdbBridge.shared.listDevices()) ?? []
        let stillThere = present.contains(serial)
            || present.contains(where: { serial.hasPrefix($0 + ":") || $0.hasPrefix(serial) })
        guard stillThere else {
            engine.markRecovering(detail: String(localized: "Device not in adb devices — plug USB or re-pair Wi‑Fi."))
            return
        }

        do {
            engine.markRecovering(detail: String(localized: "Pushing server & opening tunnel…"))
            try ServerLauncher.shared.launchServer(serial: serial, localPort: engine.port)
            try? await Task.sleep(for: .milliseconds(900))
            engine.markRecovering(detail: String(localized: "Reopening data channel…"))
            engine.transport.reconnect()
        } catch {
            // Last resort: socket-only reconnect (forward/server may still be up).
            engine.markRecovering(detail: String(localized: "Server launch failed — retrying socket…"))
            engine.transport.reconnect()
        }
    }

    /// Disconnects a specific device: stops the engine, removes its forward,
    /// drops it from the pool. If it was active, falls back to the first
    /// remaining engine (or nil).
    func disconnect(_ serial: String) {
        guard let idx = engines.firstIndex(where: { $0.deviceSerial == serial }) else { return }
        let engine = engines[idx]
        engine.stop()
        try? PortForwarder.shared.unforward(serial: serial, localPort: engine.port)
        engines.remove(at: idx)
        // Remember intentional disconnect so ConnectionView doesn't immediately
        // re-open a session for the still-online wireless adb endpoint.
        autoConnectSuppressed.insert(serial)
        if activeDeviceId == serial {
            activeDeviceId = engines.first?.deviceSerial
        }
        // Let ScrcpyController / UI tear down mirror + recording for this device.
        NotificationCenter.default.post(name: .deviceSessionRemoved, object: serial)
    }

    /// Disconnects every device. Called on app teardown.
    func disconnectAll() {
        let serials = engines.map(\.deviceSerial)
        for engine in engines {
            autoConnectSuppressed.insert(engine.deviceSerial)
            engine.stop()
            try? PortForwarder.shared.unforward(serial: engine.deviceSerial, localPort: engine.port)
        }
        engines.removeAll()
        activeDeviceId = nil
        for serial in serials {
            NotificationCenter.default.post(name: .deviceSessionRemoved, object: serial)
        }
    }

    /// Drop suppression for serials no longer present in adb — a re-plug or
    /// fresh wireless connect should auto-connect again.
    func syncAutoConnectSuppression(withPresentSerials list: [String]) {
        let present = Set(list)
        autoConnectSuppressed = autoConnectSuppressed.intersection(present)
    }

    /// Whether ConnectionView may auto-start a session for this serial.
    func shouldAutoConnect(serial: String) -> Bool {
        !autoConnectSuppressed.contains(serial)
    }
}
