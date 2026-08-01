import Foundation

final class AdbBridge: @unchecked Sendable {
    static let shared = AdbBridge()

    /// Best-effort caches so disconnect grouping does not shell out on the main thread.
    private let cacheLock = NSLock()
    private var modelCache: [String: String] = [:]
    private var usbIpCache: [String: String] = [:]

    struct DeviceInfo: Hashable, Sendable {
        let serial: String
        let state: String
        var isReady: Bool { state == "device" }
    }

    struct StorageInfo {
        let totalBytes: Int64
        let usedBytes: Int64
    }

    func listDevices() throws -> [String] {
        try listAllDevicesWithState().filter(\.isReady).map(\.serial)
    }

    func listAllDevicesWithState() throws -> [DeviceInfo] {
        guard let adb = AdbLocator.shared.findAdb() else { throw AdbError.notFound }
        let out = try AdbRunner.run(adb, args: ["devices"], timeout: 5)
        return out.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 2 else { return nil }
            return DeviceInfo(serial: String(parts[0]), state: String(parts[1]))
        }
    }

    func getBatteryLevel(serial: String) -> Int? {
        guard let adb = AdbLocator.shared.findAdb(),
              let out = try? AdbRunner.run(
                adb,
                args: ["-s", serial, "shell", "dumpsys", "battery"],
                timeout: 5
              ) else { return nil }
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("level:") {
                return Int(t.dropFirst("level:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// Human-readable model (`ro.product.model`), best-effort. Empty / failed → nil.
    func getDeviceModel(serial: String) -> String? {
        cacheLock.lock()
        if let cached = modelCache[serial] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        guard let adb = AdbLocator.shared.findAdb(),
              let out = try? AdbRunner.run(
                adb,
                args: ["-s", serial, "shell", "getprop", "ro.product.model"],
                timeout: 5
              )
        else { return nil }
        let model = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model != "unknown" else { return nil }
        cacheLock.lock()
        modelCache[serial] = model
        cacheLock.unlock()
        return model
    }

    /// Cached LAN IP for a USB serial (no shell). Used for dual-link disconnect expand.
    func cachedUsbIp(serial: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return usbIpCache[serial]
    }

    func rememberUsbIp(serial: String, ip: String) {
        cacheLock.lock()
        usbIpCache[serial] = ip
        cacheLock.unlock()
    }

    func clearDeviceCaches(serial: String) {
        cacheLock.lock()
        modelCache.removeValue(forKey: serial)
        usbIpCache.removeValue(forKey: serial)
        cacheLock.unlock()
    }

    func getStorageInfo(serial: String) -> StorageInfo? {
        guard let adb = AdbLocator.shared.findAdb(),
              let out = try? AdbRunner.run(
                adb,
                args: ["-s", serial, "shell", "df", "/sdcard"],
                timeout: 5
              ) else { return nil }
        for line in out.split(separator: "\n").dropFirst() {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 4,
               let total = Int64(parts[1]),
               let used = Int64(parts[2]) {
                return StorageInfo(totalBytes: total * 1024, usedBytes: used * 1024)
            }
        }
        return nil
    }

    /// host:port for wireless adb (pairing or connection).
    struct WifiEndpoint: Hashable, Sendable {
        let host: String
        let port: Int
        var display: String { "\(host):\(port)" }
        /// Serial as shown by `adb devices` after connect.
        var serial: String { display }

        static func parse(_ raw: String) -> WifiEndpoint? {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return nil }
            // Allow "host:port" or bare host (default 5555).
            if let colon = s.lastIndex(of: ":") {
                let host = String(s[..<colon]).trimmingCharacters(in: .whitespaces)
                let portStr = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                guard !host.isEmpty, let port = Int(portStr), port > 0, port < 65536 else { return nil }
                return WifiEndpoint(host: host, port: port)
            }
            // Bare IPv4 / hostname → default wireless port
            guard s.rangeOfCharacter(from: .whitespaces) == nil else { return nil }
            return WifiEndpoint(host: s, port: 5555)
        }
    }

    func enableTcpip(serial: String, port: Int = 5555) throws {
        guard let adb = AdbLocator.shared.findAdb() else { throw AdbError.notFound }
        _ = try AdbRunner.run(
            adb,
            args: ["-s", serial, "tcpip", String(port)],
            timeout: 10
        )
    }

    /// Best-effort LAN IP while USB adb still works. Tries several shells —
    /// HyperOS/MIUI often use different interface names than stock wlan0.
    func getDeviceIp(serial: String) -> String? {
        if let cached = cachedUsbIp(serial: serial) { return cached }
        guard let adb = AdbLocator.shared.findAdb() else { return nil }
        let commands: [[String]] = [
            // Prefer Wi-Fi interface first
            ["-s", serial, "shell", "ip", "-f", "inet", "addr", "show", "wlan0"],
            ["-s", serial, "shell", "ip", "-f", "inet", "addr", "show", "wlan1"],
            ["-s", serial, "shell", "ip", "-f", "inet", "addr", "show", "wifi0"],
            // Route to internet → source IP of active interface
            ["-s", serial, "shell", "ip", "route", "get", "1.1.1.1"],
            ["-s", serial, "shell", "ip", "route", "get", "8.8.8.8"],
            // All interfaces (filter loopback / link-local later)
            ["-s", serial, "shell", "ip", "-f", "inet", "addr", "show"],
            ["-s", serial, "shell", "ifconfig", "wlan0"],
            ["-s", serial, "shell", "getprop", "dhcp.wlan0.ipaddress"],
            ["-s", serial, "shell", "getprop", "dhcp.eth0.ipaddress"],
        ]
        for args in commands {
            guard let out = try? AdbRunner.run(adb, args: args, timeout: 5) else { continue }
            if let ip = Self.firstIPv4(in: out) {
                rememberUsbIp(serial: serial, ip: ip)
                return ip
            }
        }
        return nil
    }

    /// Restore USB transport after a failed/partial `tcpip` switch.
    func restoreUsb(serial: String) {
        guard let adb = AdbLocator.shared.findAdb() else { return }
        _ = try? AdbRunner.run(adb, args: ["-s", serial, "usb"], timeout: 10)
        // Give the daemon a moment to re-enumerate the USB device.
        Thread.sleep(forTimeInterval: 0.8)
        _ = try? AdbRunner.run(adb, args: ["reconnect"], timeout: 10)
        Thread.sleep(forTimeInterval: 0.5)
    }

    private static func firstIPv4(in text: String) -> String? {
        // Skip loopback and link-local; prefer private LAN ranges when present.
        let pattern = #"\b(\d{1,3}(?:\.\d{1,3}){3})\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var candidates: [String] = []
        for m in matches {
            let ip = ns.substring(with: m.range(at: 1))
            if ip.hasPrefix("127.") { continue }
            if ip.hasPrefix("0.") { continue }
            if ip.hasPrefix("169.254.") { continue } // link-local
            // Reject obviously invalid octets quickly
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { continue }
            candidates.append(ip)
        }
        // Prefer common private LAN ranges
        if let priv = candidates.first(where: {
            $0.hasPrefix("192.168.") || $0.hasPrefix("10.") || $0.hasPrefix("172.")
        }) {
            return priv
        }
        return candidates.first
    }

    /// `adb connect host:port` — validates output (exit 0 alone is not enough).
    @discardableResult
    func connectWifi(host: String, port: Int = 5555) throws -> String {
        try connectWifi(WifiEndpoint(host: host, port: port))
    }

    @discardableResult
    func connectWifi(_ endpoint: WifiEndpoint) throws -> String {
        guard let adb = AdbLocator.shared.findAdb() else { throw AdbError.notFound }
        let target = endpoint.display
        let out: String
        do {
            out = try AdbRunner.run(adb, args: ["connect", target], timeout: 10)
        } catch let AdbError.commandFailed(_, stderr) {
            throw AdbError.wifiConnectFailed(message: humanizeConnectError(stderr, target: target))
        }
        let lower = out.lowercased()
        if lower.contains("connected to") || lower.contains("already connected to") {
            rememberWifiEndpoint(endpoint)
            return endpoint.serial
        }
        throw AdbError.wifiConnectFailed(message: humanizeConnectError(out, target: target))
    }

    /// Drop a wireless adb endpoint (`adb disconnect host:port`).
    /// No-op for USB serials. Best-effort — ignore command failures.
    func disconnectWifi(_ serial: String) {
        guard serial.contains(":") else { return }
        guard let adb = AdbLocator.shared.findAdb() else { return }
        _ = try? AdbRunner.run(adb, args: ["disconnect", serial], timeout: 5)
    }

    /// Connect using a remembered endpoint; if the port is stale, try mDNS
    /// `_adb-tls-connect` services on the same host (then any discovered host).
    @discardableResult
    func connectWifiResolving(_ endpoint: WifiEndpoint) throws -> String {
        do {
            return try connectWifi(endpoint)
        } catch {
            let firstError = error
            let mdns = listMdnsConnectEndpoints()
            // Prefer same host, different port; then any other connect endpoint.
            var candidates = mdns.filter { $0.host == endpoint.host && $0.port != endpoint.port }
            candidates.append(contentsOf: mdns.filter { $0.host != endpoint.host })
            // De-dupe
            var seen = Set<String>()
            candidates = candidates.filter { seen.insert($0.display).inserted }

            for alt in candidates {
                if let serial = try? connectWifi(alt) {
                    return serial
                }
            }
            throw firstError
        }
    }

    // MARK: - mDNS (wireless debugging discovery)

    /// One line from `adb mdns services` (connect or pairing).
    struct MdnsService: Hashable, Sendable {
        enum Kind: String, Sendable {
            case tlsConnect
            case tlsPairing
            case other
        }
        let name: String
        let kind: Kind
        let endpoint: WifiEndpoint
    }

    /// Best-effort `adb mdns services`. Empty when adb missing, mDNS off, or nothing on LAN.
    func listMdnsServices() -> [MdnsService] {
        guard let adb = AdbLocator.shared.findAdb() else { return [] }
        let out: String
        do {
            out = try AdbRunner.run(adb, args: ["mdns", "services"], timeout: 8)
        } catch {
            return []
        }
        return Self.parseMdnsServices(out)
    }

    /// Connect ports only (`_adb-tls-connect._tcp`) — safe for `adb connect`.
    func listMdnsConnectEndpoints() -> [WifiEndpoint] {
        listMdnsServices()
            .filter { $0.kind == .tlsConnect }
            .map(\.endpoint)
    }

    /// Pure parser for tests and offline use.
    static func parseMdnsServices(_ output: String) -> [MdnsService] {
        var result: [MdnsService] = []
        // Examples:
        //   adb-XXXX._adb-tls-connect._tcp.  192.168.1.8:41567
        //   adb-XXXX._adb-tls-pairing._tcp   192.168.1.8:37123
        let pattern = #"(\S*?(_adb-tls-connect|_adb-tls-pairing|_adb)\._tcp\.?)\s+(\d{1,3}(?:\.\d{1,3}){3}):(\d{2,5})"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }
        let ns = output as NSString
        let matches = re.matches(in: output, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            guard m.numberOfRanges >= 5 else { continue }
            let name = ns.substring(with: m.range(at: 1))
            let kindToken = ns.substring(with: m.range(at: 2)).lowercased()
            let host = ns.substring(with: m.range(at: 3))
            guard let port = Int(ns.substring(with: m.range(at: 4))),
                  let ep = WifiEndpoint.parse("\(host):\(port)") else { continue }
            let kind: MdnsService.Kind
            if kindToken.contains("tls-connect") {
                kind = .tlsConnect
            } else if kindToken.contains("tls-pairing") {
                kind = .tlsPairing
            } else {
                kind = .other
            }
            result.append(MdnsService(name: name, kind: kind, endpoint: ep))
        }
        return result
    }

    /// `adb pair host:port code`
    func pair(host: String, port: Int, code: String) throws {
        try pair(WifiEndpoint(host: host, port: port), code: code)
    }

    func pair(_ endpoint: WifiEndpoint, code: String) throws {
        guard let adb = AdbLocator.shared.findAdb() else { throw AdbError.notFound }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else {
            throw AdbError.wifiPairFailed(message: String(localized: "Pairing code must be at least 6 digits."))
        }
        let out: String
        do {
            out = try AdbRunner.run(
                adb,
                args: ["pair", endpoint.display, trimmed],
                timeout: 30
            )
        } catch let AdbError.commandFailed(_, stderr) {
            throw AdbError.wifiPairFailed(message: humanizePairError(stderr))
        }
        let lower = out.lowercased()
        guard lower.contains("successfully paired") || lower.contains("success") else {
            throw AdbError.wifiPairFailed(message: humanizePairError(out))
        }
    }

    /// One-shot: pair (if code provided path) then connect — used by UI “Pair & Connect”.
    func pairAndConnect(pairEndpoint: WifiEndpoint, code: String, connectEndpoint: WifiEndpoint) throws -> String {
        try pair(pairEndpoint, code: code)
        // Brief settle — some devices need a moment after pair before connect works.
        Thread.sleep(forTimeInterval: 0.4)
        return try connectWifi(connectEndpoint)
    }

    /// USB device → read LAN IP **first** → `adb tcpip` → `adb connect`.
    ///
    /// Important: IP must be read *before* `tcpip`. After `tcpip`, many phones
    /// drop or rebind the USB adb session, so shell can fail and leave USB
    /// “broken” until `adb usb` / reconnect. On failure we always try to restore USB.
    func enableWirelessFromUSB(serial: String, port: Int = 5555) throws -> String {
        // 1) Capture IP while USB transport is still healthy.
        guard let ip = getDeviceIp(serial: serial) else {
            throw AdbError.wifiConnectFailed(
                message: String(localized: "Could not read the phone’s Wi-Fi IP over USB. Turn Wi-Fi on, stay on the same network as this Mac, then retry — or use “Pair & Connect” with the IP from the phone.")
            )
        }
        let endpoint = WifiEndpoint(host: ip, port: port)

        // 2) Switch device adb to TCP. May disrupt the USB serial briefly.
        do {
            try enableTcpip(serial: serial, port: port)
        } catch {
            restoreUsb(serial: serial)
            throw AdbError.wifiConnectFailed(
                message: String(localized: "Failed to enable wireless adb (tcpip). USB has been restored. \(error.localizedDescription)")
            )
        }
        Thread.sleep(forTimeInterval: 0.8)

        // 3) Connect over the network. If this fails, put the phone back on USB.
        do {
            return try connectWifi(endpoint)
        } catch {
            restoreUsb(serial: serial)
            throw AdbError.wifiConnectFailed(
                message: String(localized: "Wireless connect to \(endpoint.display) failed; USB mode restored. \(error.localizedDescription)")
            )
        }
    }

    // MARK: - Recent wireless endpoints

    private static let recentKey = "wifi.recent_endpoints"
    private static let maxRecent = 8

    func recentWifiEndpoints() -> [WifiEndpoint] {
        let raw = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        return raw.compactMap { WifiEndpoint.parse($0) }
    }

    func rememberWifiEndpoint(_ endpoint: WifiEndpoint) {
        // One entry per host — ports change often on wireless debugging.
        var list = recentWifiEndpoints().filter { $0.host != endpoint.host }
        list.insert(endpoint, at: 0)
        if list.count > Self.maxRecent { list = Array(list.prefix(Self.maxRecent)) }
        UserDefaults.standard.set(list.map(\.display), forKey: Self.recentKey)
    }

    func removeRecentWifiEndpoint(_ endpoint: WifiEndpoint) {
        var list = recentWifiEndpoints().map(\.display)
        list.removeAll { $0 == endpoint.display || $0.hasPrefix(endpoint.host + ":") }
        UserDefaults.standard.set(list, forKey: Self.recentKey)
    }

    func clearRecentWifiEndpoints() {
        UserDefaults.standard.removeObject(forKey: Self.recentKey)
    }

    private func humanizePairError(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            return String(localized: "Pairing failed. Keep the pairing sheet open, re-open “Pair with pairing code” for a fresh port and 6-digit code, then retry immediately.")
        }
        let lower = t.lowercased()
        if lower.contains("protocol fault")
            || lower.contains("connection refused")
            || lower.contains("failed to connect")
            || lower.contains("no route")
            || lower.contains("timed out")
            || lower.contains("timeout") {
            // Most common: pair sheet closed, port expired, or main-screen port pasted by mistake.
            return String(localized: "Pairing failed: cannot reach the pairing port. Re-open “Pair with pairing code” on the phone (keep that sheet open), copy the new IP:port + code, and make sure Mac and phone are on the same Wi-Fi (turn off VPN). If the phone is already on USB, use Connect on the left instead.")
        }
        if lower.contains("failed to pair") || lower.contains("wrong") || lower.contains("incorrect") {
            return String(localized: "Pairing failed: check the 6-digit code (it expires quickly). Open a new pairing sheet and try again.")
        }
        // Prefer a localized shell when adb text is opaque.
        return String(localized: "Pairing failed: \(t)")
    }

    private func humanizeConnectError(_ raw: String, target: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if lower.contains("failed to connect") || lower.contains("no connection") {
            return String(localized: "Could not connect to \(target). Use the IP:port from the Wireless debugging main screen (not the pairing port). Same Wi-Fi as this Mac.")
        }
        if t.isEmpty {
            return String(localized: "Could not connect to \(target). Check IP, connection port, and Wi-Fi.")
        }
        return t
    }

    func installApk(serial: String, url: URL) throws {
        guard let adb = AdbLocator.shared.findAdb() else { throw AdbError.notFound }
        _ = try AdbRunner.run(adb, args: ["-s", serial, "install", "-r", url.path])
    }

    /// Preferred folder for screenshots / screen recordings (Downloads, or
    /// the user’s chosen download directory from Settings).
    nonisolated static func mediaSaveDirectory() -> URL {
        if let last = UserDefaults.standard.string(forKey: "lastDownloadDir"),
           FileManager.default.fileExists(atPath: last) {
            return URL(fileURLWithPath: last, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    // MARK: - Low-level adb helpers (background only)

    /// Run adb with discarded stdout/stderr. Returns exit status.
    nonisolated private func runAdbQuiet(_ adb: String, args: [String], timeout: TimeInterval? = nil) -> Int32 {
        do {
            _ = try AdbRunner.runData(adb, args: args, timeout: timeout)
            return 0
        } catch let AdbError.commandFailed(status, _) {
            return status
        } catch {
            return -1
        }
    }

    /// Synchronous screencap via **device file + pull**.
    ///
    /// `adb exec-out screencap -p` is unreliable on multi-display phones
    /// (warnings get mixed into stdout and corrupt the PNG). Prefer file path.
    /// **Must not** be called on the main thread.
    nonisolated func screenshot(serial: String) -> Data? {
        guard let adb = AdbLocator.shared.findAdb() else { return nil }
        let remote = "/sdcard/Download/.droidmate-shot.png"
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("droidmate-shot-\(UUID().uuidString).png")

        // Write PNG on device (stderr warnings stay on device, not in the file).
        let capStatus = runAdbQuiet(adb, args: [
            "-s", serial, "shell", "screencap", "-p", remote,
        ], timeout: 12)
        guard capStatus == 0 else { return nil }

        let pull = Process()
        pull.executableURL = URL(fileURLWithPath: adb)
        pull.arguments = ["-s", serial, "pull", remote, local.path]
        pull.standardOutput = FileHandle.nullDevice
        pull.standardError = FileHandle.nullDevice
        do {
            try pull.run()
            pull.waitUntilExit()
        } catch {
            return nil
        }
        _ = runAdbQuiet(adb, args: ["-s", serial, "shell", "rm", "-f", remote], timeout: 5)

        guard pull.terminationStatus == 0,
              let data = try? Data(contentsOf: local),
              data.count >= 24,
              data[0] == 0x89, data[1] == 0x50 else {
            try? FileManager.default.removeItem(at: local)
            return nil
        }
        try? FileManager.default.removeItem(at: local)
        return data
    }

    /// Background screencap + write to Downloads. Completion always on main.
    func screenshotAsync(
        serial: String,
        saveToDownloads: Bool = true,
        completion: @MainActor @escaping (Result<URL?, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let png = self.screenshot(serial: serial), !png.isEmpty else {
                DispatchQueue.main.async {
                    completion(.failure(AdbError.commandFailed(
                        status: -1,
                        stderr: "Screenshot failed — device busy or not authorized?"
                    )))
                }
                return
            }
            guard saveToDownloads else {
                DispatchQueue.main.async { completion(.success(nil)) }
                return
            }
            let dir = Self.mediaSaveDirectory()
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let url = dir.appendingPathComponent("DroidMate-\(fmt.string(from: Date())).png")
            do {
                try png.write(to: url)
                DispatchQueue.main.async { completion(.success(url)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Screen recording (adb screenrecord — works alongside live scrcpy)

    /// Starts `adb shell screenrecord` on device. Returns the adb Process (monitor only)
    /// and the remote path. Call from a background queue.
    nonisolated func startScreenRecord(serial: String) -> (process: Process, remotePath: String)? {
        guard let adb = AdbLocator.shared.findAdb() else { return nil }
        // Prefer Download; fall back to /sdcard if needed later on pull failure.
        let remote = "/sdcard/Download/DroidMate-recording.mp4"
        _ = runAdbQuiet(adb, args: ["-s", serial, "shell", "rm", "-f", remote], timeout: 5)
        // Kill any leftover recorder from a previous session.
        _ = runAdbQuiet(adb, args: [
            "-s", serial, "shell", "pkill", "-l", "INT", "screenrecord",
        ], timeout: 3)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        // --time-limit 180 safety cap; user can stop earlier by signaling the
        // *device-side* screenrecord (not this adb client).
        p.arguments = [
            "-s", serial, "shell",
            "screenrecord", "--bit-rate", "8M", "--time-limit", "180", remote,
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            // Brief settle so file is created before a quick stop.
            Thread.sleep(forTimeInterval: 0.35)
            return (p, remote)
        } catch {
            return nil
        }
    }

    /// Stop device screenrecord cleanly, wait for moov atom, pull to Downloads.
    nonisolated func finishScreenRecord(
        serial: String,
        process: Process,
        remotePath: String
    ) -> URL? {
        guard let adb = AdbLocator.shared.findAdb() else { return nil }

        // CRITICAL: SIGINT the *on-device* screenrecord so it writes moov.
        // Interrupting the local `adb` process often yields a corrupt mp4.
        _ = runAdbQuiet(adb, args: [
            "-s", serial, "shell", "pkill", "-2", "screenrecord",
        ], timeout: 5)
        // Some ROMs only respond to killall
        _ = runAdbQuiet(adb, args: [
            "-s", serial, "shell", "killall", "-2", "screenrecord",
        ], timeout: 3)

        // Wait for adb shell session to end (recorder finished).
        let deadline = Date().addingTimeInterval(6)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            // Last resort — don't hard-kill immediately; try once more then terminate adb.
            _ = runAdbQuiet(adb, args: [
                "-s", serial, "shell", "pkill", "-2", "screenrecord",
            ], timeout: 2)
            Thread.sleep(forTimeInterval: 0.8)
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        // Extra flush window after process exit (encoder finalizes moov).
        Thread.sleep(forTimeInterval: 0.6)

        // Wait until remote file size stabilizes (not growing).
        var lastSize: Int64 = -1
        for _ in 0..<15 {
            let sizeOut = try? AdbRunner.run(adb, args: [
                "-s", serial, "shell", "stat", "-c", "%s", remotePath,
            ])
            let size = Int64(sizeOut?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
            if size > 1024, size == lastSize { break }
            lastSize = size
            Thread.sleep(forTimeInterval: 0.2)
        }

        let dir = Self.mediaSaveDirectory()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let local = dir.appendingPathComponent("DroidMate-\(fmt.string(from: Date())).mp4")

        let pull = Process()
        pull.executableURL = URL(fileURLWithPath: adb)
        pull.arguments = ["-s", serial, "pull", remotePath, local.path]
        pull.standardOutput = FileHandle.nullDevice
        pull.standardError = FileHandle.nullDevice
        do {
            try pull.run()
            pull.waitUntilExit()
        } catch {
            return nil
        }
        _ = runAdbQuiet(adb, args: ["-s", serial, "shell", "rm", "-f", remotePath], timeout: 5)

        guard pull.terminationStatus == 0,
              let attrs = try? FileManager.default.attributesOfItem(atPath: local.path),
              let fileSize = attrs[.size] as? NSNumber,
              fileSize.int64Value > 4096 else {
            try? FileManager.default.removeItem(at: local)
            return nil
        }

        // Reject files that never got a moov atom (quick signature: need more than
        // ftyp + free padding). Real recordings are typically >> 50KB for a few seconds.
        // Also verify ftyp exists at start.
        if let head = try? Data(contentsOf: local, options: [.mappedIfSafe]),
           head.count > 12 {
            let ftyp = head.subdata(in: 4..<8)
            if String(data: ftyp, encoding: .ascii) != "ftyp" {
                try? FileManager.default.removeItem(at: local)
                return nil
            }
        }
        return local
    }
}
