import Foundation

/// Wi‑Fi connect flows for `ConnectionView` (pair, connect, reconnect, USB→wireless).
@MainActor
enum ConnectionWifiActions {

    struct UIHooks {
        var setBusy: (Bool) -> Void
        var setStatus: (_ ok: Bool, _ message: String?) -> Void
        var setError: (String?) -> Void
        var setRecent: ([AdbBridge.WifiEndpoint]) -> Void
        var clearPairCode: () -> Void
        var preferWifiMode: () -> Void
        var refreshDevices: () -> Void
        /// Called after a full session is up (wizard can dismiss).
        var onSessionReady: (() -> Void)?
    }

    // MARK: - Pair only (wizard step 2)

    static func pairOnly(
        pairAddr: String,
        pairCode: String,
        ui: UIHooks
    ) {
        guard let pairEp = AdbBridge.WifiEndpoint.parse(pairAddr) else {
            ui.setStatus(false, String(localized: "Enter the pairing address from the phone’s pairing sheet (IP:port)."))
            return
        }
        let code = pairCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count >= 6 else {
            ui.setStatus(false, String(localized: "Enter the 6-digit pairing code. It expires quickly — open the sheet again if needed."))
            return
        }
        ui.setBusy(true)
        ui.setStatus(true, String(localized: "Pairing…"))
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
                ui.setStatus(true, String(localized: "Paired. Next: use the main-screen IP & port to connect."))
                ui.clearPairCode()
            case .failure(let error):
                ui.setStatus(false, productPairMessage(error))
            }
            ui.setBusy(false)
        }
    }

    // MARK: - Connect only (wizard step 3)

    static func connectOnly(
        connectAddr: String,
        connMgr: ConnectionManager,
        ui: UIHooks
    ) {
        guard let connectEp = AdbBridge.WifiEndpoint.parse(connectAddr) else {
            ui.setStatus(false, String(localized: "Enter the connection address from the Wireless debugging **main screen** (IP:port) — not the pairing sheet."))
            return
        }
        ui.setBusy(true)
        ui.setStatus(true, String(localized: "Connecting over Wi‑Fi…"))
        Task {
            let connectOutcome = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                do {
                    // After pair, prefer explicit port; mDNS resolve if stale.
                    let serial = try AdbBridge.shared.connectWifiResolving(connectEp)
                    for _ in 0..<20 {
                        try await Task.sleep(for: .milliseconds(250))
                        let list = (try? AdbBridge.shared.listDevices()) ?? []
                        if list.contains(serial) || list.contains(where: { $0.hasPrefix(connectEp.host) }) {
                            let match = list.first(where: { $0 == serial || $0.hasPrefix(connectEp.host + ":") }) ?? serial
                            return .success(match)
                        }
                    }
                    return .success(serial)
                } catch {
                    return .failure(error)
                }
            }.value
            switch connectOutcome {
            case .success(let serial):
                ui.setStatus(true, String(localized: "Starting DroidMate…"))
                ui.setRecent(AdbBridge.shared.recentWifiEndpoints())
                do {
                    try await connMgr.addDevice(serial: serial)
                    ui.setStatus(true, String(localized: "Connected over Wi‑Fi (\(serial))"))
                    ui.onSessionReady?()
                } catch {
                    ui.setStatus(false, String(localized: "Phone is on adb, but DroidMate couldn’t start: \(error.localizedDescription)"))
                    ui.setError(error.localizedDescription)
                }
            case .failure(let error):
                ui.setStatus(false, productConnectMessage(error))
            }
            ui.setBusy(false)
        }
    }

    /// Legacy one-shot: pair then connect (kept for callers/tests).
    static func pairAndConnect(
        pairAddr: String,
        pairCode: String,
        connectAddr: String,
        connMgr: ConnectionManager,
        ui: UIHooks
    ) {
        guard let pairEp = AdbBridge.WifiEndpoint.parse(pairAddr),
              let connectEp = AdbBridge.WifiEndpoint.parse(connectAddr) else {
            ui.setStatus(false, String(localized: "Enter valid pairing and connection addresses (IP:port)."))
            return
        }
        let code = pairCode
        ui.setBusy(true)
        ui.setStatus(true, String(localized: "1/3 Pairing…"))
        Task {
            let pairOutcome = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                do {
                    try AdbBridge.shared.pair(pairEp, code: code)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            if case .failure(let error) = pairOutcome {
                ui.setStatus(false, productPairMessage(error))
                ui.setBusy(false)
                return
            }

            ui.setStatus(true, String(localized: "2/3 Connecting over Wi‑Fi…"))
            let connectOutcome = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                do {
                    try await Task.sleep(for: .milliseconds(400))
                    let serial = try AdbBridge.shared.connectWifi(connectEp)
                    for _ in 0..<20 {
                        try await Task.sleep(for: .milliseconds(250))
                        let list = (try? AdbBridge.shared.listDevices()) ?? []
                        if list.contains(serial) || list.contains(where: { $0.hasPrefix(connectEp.host) }) {
                            let match = list.first(where: { $0 == serial || $0.hasPrefix(connectEp.host + ":") }) ?? serial
                            return .success(match)
                        }
                    }
                    return .success(serial)
                } catch {
                    return .failure(error)
                }
            }.value
            switch connectOutcome {
            case .success(let serial):
                ui.setStatus(true, String(localized: "3/3 Starting DroidMate…"))
                ui.setRecent(AdbBridge.shared.recentWifiEndpoints())
                do {
                    try await connMgr.addDevice(serial: serial)
                    ui.setStatus(true, String(localized: "Connected over Wi‑Fi (\(serial))"))
                    ui.clearPairCode()
                    ui.onSessionReady?()
                } catch {
                    ui.setStatus(false, error.localizedDescription)
                    ui.setError(error.localizedDescription)
                }
            case .failure(let error):
                ui.setStatus(false, productConnectMessage(error))
            }
            ui.setBusy(false)
        }
    }

    static func reconnect(
        _ endpoint: AdbBridge.WifiEndpoint,
        connMgr: ConnectionManager,
        ui: UIHooks
    ) {
        ui.setBusy(true)
        ui.setStatus(true, String(localized: "Connecting to \(endpoint.display)…"))
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                do {
                    // Tries remembered port, then mDNS `_adb-tls-connect` if the port changed.
                    let serial = try AdbBridge.shared.connectWifiResolving(endpoint)
                    try await Task.sleep(for: .milliseconds(500))
                    return .success(serial)
                } catch {
                    return .failure(error)
                }
            }.value
            switch outcome {
            case .success(let serial):
                ui.setRecent(AdbBridge.shared.recentWifiEndpoints())
                let portRefreshed = serial != endpoint.display
                ui.setStatus(
                    true,
                    portRefreshed
                        ? String(localized: "Port updated. Starting DroidMate…")
                        : String(localized: "Starting DroidMate…")
                )
                do {
                    try await connMgr.addDevice(serial: serial)
                    ui.setStatus(true, String(localized: "Connected over Wi‑Fi (\(serial))"))
                    ui.onSessionReady?()
                } catch {
                    ui.setStatus(false, String(localized: "Phone is on adb, but DroidMate couldn’t start: \(error.localizedDescription)"))
                }
            case .failure(let error):
                ui.setStatus(false, productConnectMessage(error, endpoint: endpoint))
            }
            ui.setBusy(false)
        }
    }

    /// USB → wireless; replaces USB DroidMate session on success.
    static func enableWirelessFromUSB(
        serial: String,
        connMgr: ConnectionManager,
        ui: UIHooks
    ) {
        ui.setBusy(true)
        ui.setStatus(true, String(localized: "1/3 Reading phone IP…"))
        Task {
            let ipOutcome = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                if let ip = AdbBridge.shared.getDeviceIp(serial: serial) {
                    return .success(ip)
                }
                return .failure(AdbError.wifiConnectFailed(
                    message: String(localized: "Couldn’t read the phone’s Wi‑Fi IP over USB. Turn Wi‑Fi on, stay on the same network as this Mac — or use Add phone with the IP from Wireless debugging.")
                ))
            }.value
            guard case .success(let ip) = ipOutcome else {
                if case .failure(let error) = ipOutcome {
                    ui.setStatus(false, error.localizedDescription)
                }
                ui.setBusy(false)
                return
            }

            ui.setStatus(true, String(localized: "2/3 Enabling wireless adb…"))
            let port = 5555
            let tcpipOutcome = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                do {
                    try AdbBridge.shared.enableTcpip(serial: serial, port: port)
                    try await Task.sleep(for: .milliseconds(800))
                    return .success(())
                } catch {
                    AdbBridge.shared.restoreUsb(serial: serial)
                    return .failure(AdbError.wifiConnectFailed(
                        message: String(localized: "Couldn’t enable wireless adb. USB was restored. \(error.localizedDescription)")
                    ))
                }
            }.value
            if case .failure(let error) = tcpipOutcome {
                ui.setStatus(false, error.localizedDescription)
                ui.refreshDevices()
                ui.setBusy(false)
                return
            }

            ui.setStatus(true, String(localized: "3/3 Connecting over Wi‑Fi…"))
            let endpoint = AdbBridge.WifiEndpoint(host: ip, port: port)
            let connectOutcome = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                do {
                    let wifiSerial = try AdbBridge.shared.connectWifi(endpoint)
                    try await Task.sleep(for: .milliseconds(400))
                    return .success(wifiSerial)
                } catch {
                    AdbBridge.shared.restoreUsb(serial: serial)
                    return .failure(AdbError.wifiConnectFailed(
                        message: String(localized: "Wireless connect to \(endpoint.display) failed; USB restored. \(error.localizedDescription)")
                    ))
                }
            }.value

            switch connectOutcome {
            case .success(let wifiSerial):
                ui.setRecent(AdbBridge.shared.recentWifiEndpoints())
                ui.setStatus(true, String(localized: "Starting DroidMate…"))
                do {
                    if !connMgr.engines.contains(where: { $0.deviceSerial == wifiSerial }) {
                        try await connMgr.addDevice(serial: wifiSerial)
                    } else {
                        connMgr.switchTo(wifiSerial)
                    }
                    if wifiSerial != serial, connMgr.engines.contains(where: { $0.deviceSerial == serial }) {
                        connMgr.disconnect(serial)
                    }
                    connMgr.switchTo(wifiSerial)
                    ui.setStatus(true, String(localized: "On Wi‑Fi (\(wifiSerial)). Safe to unplug USB."))
                    ui.preferWifiMode()
                    ui.refreshDevices()
                    ui.onSessionReady?()
                } catch {
                    ui.setStatus(
                        false,
                        String(localized: "Wireless adb is up (\(wifiSerial)) but DroidMate failed: \(error.localizedDescription)")
                    )
                    ui.refreshDevices()
                }
            case .failure(let error):
                ui.setStatus(false, error.localizedDescription)
                ui.refreshDevices()
            }
            ui.setBusy(false)
        }
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
        let target = endpoint?.display ?? ""
        return String(localized: "Couldn’t connect\(target.isEmpty ? "" : " to \(target)"). Open Wireless debugging on the phone and use the **main screen** IP & port (not the pairing sheet). Same Wi‑Fi as this Mac.")
    }
}
