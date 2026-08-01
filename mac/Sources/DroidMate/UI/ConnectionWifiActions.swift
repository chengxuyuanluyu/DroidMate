import Combine
import Foundation

/// Form, progress and wizard state owned by the connection workspace.
@MainActor
final class ConnectionWifiState: ObservableObject {
    @Published var pairAddr = ""
    @Published var pairCode = ""
    @Published var connectAddr = ""
    @Published var status: String?
    @Published var statusOK = false
    @Published var isBusy = false
    @Published var recent: [AdbBridge.WifiEndpoint] = []
    @Published var wizardPairSucceeded = false
    @Published var wizardSessionReady = false

    func setStatus(_ ok: Bool, _ message: String?) {
        statusOK = ok
        status = message
    }
}

/// Wi-Fi connect flows for `ConnectionView` (pair, connect, reconnect, USB→wireless).
///
/// User-facing strings use `String(localized:)` with English **source keys** (ASCII `Wi-Fi`).
/// Do not branch UI logic on localized status text — use the explicit wizard signals.
@MainActor
enum ConnectionWifiActions {

    // MARK: - Pair only (wizard step 2)

    static func pairOnly(state: ConnectionWifiState) {
        guard let pairEp = AdbBridge.WifiEndpoint.parse(state.pairAddr) else {
            state.setStatus(false, String(localized: "Enter the pairing address from the phone’s pairing sheet (IP:port)."))
            return
        }
        let code = state.pairCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count >= 6 else {
            state.setStatus(false, String(localized: "Enter the 6-digit pairing code. It expires quickly — open the sheet again if needed."))
            return
        }
        state.isBusy = true
        state.setStatus(true, String(localized: "Pairing…"))
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                do {
                    try AdbBridge.shared.pair(pairEp, code: code)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            switch outcome {
            case .success:
                state.setStatus(true, String(localized: "Paired. Next: use the main-screen IP & port to connect."))
                state.pairCode = ""
                state.wizardPairSucceeded = true
            case .failure(let error):
                state.setStatus(false, productPairMessage(error))
            }
            state.isBusy = false
        }
    }

    // MARK: - Connect only (wizard step 3)

    static func connectOnly(
        state: ConnectionWifiState,
        connMgr: ConnectionManager,
        onError: @escaping (String?) -> Void
    ) {
        guard let connectEp = AdbBridge.WifiEndpoint.parse(state.connectAddr) else {
            state.setStatus(false, String(localized: "Enter the connection address from the Wireless debugging main screen (IP:port) — not the pairing sheet."))
            return
        }
        state.isBusy = true
        state.setStatus(true, String(localized: "Connecting over Wi-Fi…"))
        connMgr.startConnectionWorkflow {
            defer { state.isBusy = false }
            // Register the intended endpoint *before* adb connect. Cancellation
            // can win after a successful child process, so we must not rely on
            // the returned serial existing before note/rollback.
            var serial: String = connectEp.serial
            connMgr.noteProvisionalWireless(serial)
            do {
                let initial = try await ConnectionManager.runAdbOperation {
                    try AdbBridge.shared.connectWifiResolving(connectEp)
                }
                if initial != serial {
                    connMgr.clearProvisionalWireless(serial)
                    connMgr.noteProvisionalWireless(initial)
                    serial = initial
                }
                var resolved = initial
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(250))
                    let list: [String]
                    do {
                        list = try await ConnectionManager.runAdbOperation {
                            try AdbBridge.shared.listDevices()
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        list = []
                    }
                    if list.contains(initial) || list.contains(where: { $0.hasPrefix(connectEp.host) }) {
                        resolved = list.first(where: {
                            $0 == initial || $0.hasPrefix(connectEp.host + ":")
                        }) ?? initial
                        break
                    }
                }
                try Task.checkCancellation()
                if resolved != serial {
                    connMgr.clearProvisionalWireless(serial)
                    connMgr.noteProvisionalWireless(resolved)
                    serial = resolved
                }
            } catch is CancellationError {
                await rollbackWirelessConnection(serial: serial, connMgr: connMgr)
                return
            } catch {
                await rollbackWirelessConnection(serial: serial, connMgr: connMgr)
                state.setStatus(false, productConnectMessage(error))
                return
            }

            state.setStatus(true, String(localized: "Starting DroidMate…"))
            state.recent = AdbBridge.shared.recentWifiEndpoints()
            do {
                try await connMgr.addDevice(serial: serial)
                try Task.checkCancellation()
                state.setStatus(true, String(localized: "Connected over Wi-Fi (\(serial))"))
                state.wizardSessionReady = true
            } catch is CancellationError {
                await rollbackWirelessConnection(serial: serial, connMgr: connMgr)
            } catch {
                state.setStatus(false, String(localized: "Phone is on adb, but DroidMate couldn’t start: \(error.localizedDescription)"))
                onError(error.localizedDescription)
            }
        }
    }

    static func reconnect(
        _ endpoint: AdbBridge.WifiEndpoint,
        connMgr: ConnectionManager,
        state: ConnectionWifiState
    ) {
        state.isBusy = true
        state.setStatus(true, String(localized: "Connecting to \(endpoint.display)…"))
        connMgr.startConnectionWorkflow {
            defer { state.isBusy = false }
            var serial: String = endpoint.serial
            connMgr.noteProvisionalWireless(serial)
            do {
                let connected = try await ConnectionManager.runAdbOperation {
                    try AdbBridge.shared.connectWifiResolving(endpoint)
                }
                if connected != serial {
                    connMgr.clearProvisionalWireless(serial)
                    connMgr.noteProvisionalWireless(connected)
                    serial = connected
                }
                try await Task.sleep(for: .milliseconds(500))
            } catch is CancellationError {
                await rollbackWirelessConnection(serial: serial, connMgr: connMgr)
                return
            } catch {
                await rollbackWirelessConnection(serial: serial, connMgr: connMgr)
                state.setStatus(false, productConnectMessage(error, endpoint: endpoint))
                return
            }

            state.recent = AdbBridge.shared.recentWifiEndpoints()
            let portRefreshed = serial != endpoint.display
            state.setStatus(
                true,
                portRefreshed
                    ? String(localized: "Port updated. Starting DroidMate…")
                    : String(localized: "Starting DroidMate…")
            )
            do {
                try await connMgr.addDevice(serial: serial)
                try Task.checkCancellation()
                state.setStatus(true, String(localized: "Connected over Wi-Fi (\(serial))"))
                state.wizardSessionReady = true
            } catch is CancellationError {
                await rollbackWirelessConnection(serial: serial, connMgr: connMgr)
            } catch {
                state.setStatus(false, String(localized: "Phone is on adb, but DroidMate couldn’t start: \(error.localizedDescription)"))
            }
        }
    }

    /// USB → wireless; replaces USB DroidMate session on success.
    static func enableWirelessFromUSB(
        serial: String,
        connMgr: ConnectionManager,
        state: ConnectionWifiState,
        refreshDevices: @escaping () -> Void
    ) {
        state.isBusy = true
        state.setStatus(true, String(localized: "1/3 Reading phone IP…"))
        connMgr.startConnectionWorkflow {
            defer { state.isBusy = false }
            let ip: String
            do {
                guard let resolved = try await ConnectionManager.runAdbOperation({
                    AdbBridge.shared.getDeviceIp(serial: serial)
                }) else {
                    throw AdbError.wifiConnectFailed(
                        message: String(localized: "Couldn’t read the phone’s Wi-Fi IP over USB. Turn Wi-Fi on, stay on the same network as this Mac — or use Add phone with the IP from Wireless debugging.")
                    )
                }
                ip = resolved
            } catch is CancellationError {
                return
            } catch {
                state.setStatus(false, error.localizedDescription)
                return
            }

            state.setStatus(true, String(localized: "2/3 Enabling wireless adb…"))
            let port = 5555
            do {
                try await ConnectionManager.runAdbOperation {
                    try AdbBridge.shared.enableTcpip(serial: serial, port: port)
                }
                try await Task.sleep(for: .milliseconds(800))
            } catch is CancellationError {
                await rollbackWirelessConnection(serial: nil, restoreUSBSerial: serial, connMgr: connMgr)
                return
            } catch {
                await rollbackWirelessConnection(serial: nil, restoreUSBSerial: serial, connMgr: connMgr)
                state.setStatus(
                    false,
                    String(localized: "Couldn’t enable wireless adb. USB was restored. \(error.localizedDescription)")
                )
                refreshDevices()
                return
            }

            state.setStatus(true, String(localized: "3/3 Connecting over Wi-Fi…"))
            let endpoint = AdbBridge.WifiEndpoint(host: ip, port: port)
            var wifiSerial: String = endpoint.serial
            connMgr.noteProvisionalWireless(wifiSerial)
            do {
                let connected = try await ConnectionManager.runAdbOperation {
                    try AdbBridge.shared.connectWifi(endpoint)
                }
                if connected != wifiSerial {
                    connMgr.clearProvisionalWireless(wifiSerial)
                    connMgr.noteProvisionalWireless(connected)
                    wifiSerial = connected
                }
                try await Task.sleep(for: .milliseconds(400))
            } catch is CancellationError {
                await rollbackWirelessConnection(
                    serial: wifiSerial,
                    restoreUSBSerial: serial,
                    connMgr: connMgr
                )
                return
            } catch {
                await rollbackWirelessConnection(
                    serial: wifiSerial,
                    restoreUSBSerial: serial,
                    connMgr: connMgr
                )
                state.setStatus(
                    false,
                    String(localized: "Wireless connect to \(endpoint.display) failed; USB restored. \(error.localizedDescription)")
                )
                refreshDevices()
                return
            }

            state.recent = AdbBridge.shared.recentWifiEndpoints()
            state.setStatus(true, String(localized: "Starting DroidMate…"))
            do {
                if !connMgr.engines.contains(where: { $0.deviceSerial == wifiSerial }) {
                    try await connMgr.addDevice(serial: wifiSerial)
                } else {
                    connMgr.clearProvisionalWireless(wifiSerial)
                    connMgr.switchTo(wifiSerial)
                }
                try Task.checkCancellation()
                // Drop USB session after Wi-Fi is up (sibling expand not needed —
                // we keep the new wifi session and only end the USB serial).
                if wifiSerial != serial, connMgr.engines.contains(where: { $0.deviceSerial == serial }) {
                    // Bypass transfer confirm: user already chose "switch";
                    // still suppress USB so auto-connect doesn't re-open cable session.
                    connMgr.disconnect(serial)
                }
                connMgr.switchTo(wifiSerial)
                state.setStatus(true, String(localized: "On Wi-Fi (\(wifiSerial)). Safe to unplug USB."))
                refreshDevices()
                state.wizardSessionReady = true
            } catch is CancellationError {
                await rollbackWirelessConnection(
                    serial: wifiSerial,
                    restoreUSBSerial: serial,
                    connMgr: connMgr
                )
            } catch {
                state.setStatus(
                    false,
                    String(localized: "Wireless adb is up (\(wifiSerial)) but DroidMate failed: \(error.localizedDescription)")
                )
                refreshDevices()
            }
        }
    }

    /// Rollback runs in a fresh task so teardown cancellation does not prevent
    /// the cleanup itself. The managed workflow awaits it, so Quit still has a
    /// single lifecycle barrier and no detached adb work escapes.
    private static func rollbackWirelessConnection(
        serial: String?,
        restoreUSBSerial: String? = nil,
        connMgr: ConnectionManager? = nil
    ) async {
        if let serial {
            connMgr?.clearProvisionalWireless(serial)
        }
        let rollback = Task {
            try? await ConnectionManager.runAdbOperation {
                if let serial {
                    AdbBridge.shared.disconnectWifi(serial)
                }
                if let restoreUSBSerial {
                    AdbBridge.shared.restoreUsb(serial: restoreUSBSerial)
                }
            }
        }
        _ = await rollback.value
    }

    // MARK: - Product-facing errors

    private static func productPairMessage(_ error: Error) -> String {
        let t = error.localizedDescription
        if t.localizedCaseInsensitiveContains("wrong port")
            || t.localizedCaseInsensitiveContains("pairing screen")
            || t.localizedCaseInsensitiveContains("protocol") {
            return t
        }
        if t.localizedCaseInsensitiveContains("code") {
            return String(localized: "Pairing failed. Check the 6-digit code — open the pairing sheet again if it expired.")
        }
        return t.isEmpty
            ? String(localized: "Pairing failed. Keep the pairing sheet open and try again.")
            : t
    }

    private static func productConnectMessage(_ error: Error, endpoint: AdbBridge.WifiEndpoint? = nil) -> String {
        let t = error.localizedDescription
        if t.localizedCaseInsensitiveContains("main screen") || t.localizedCaseInsensitiveContains("pairing port") {
            return t
        }
        if let endpoint {
            return String(localized: "Couldn’t connect to \(endpoint.display). Open Wireless debugging on the phone and use the main screen IP & port (not the pairing sheet). Same Wi-Fi as this Mac.")
        }
        return String(localized: "Couldn’t connect. Open Wireless debugging on the phone and use the main screen IP & port (not the pairing sheet). Same Wi-Fi as this Mac.")
    }
}
