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

    static let lastConnectedSerialKey = "connection.lastConnectedSerial"
    typealias CleanupOperation = @Sendable (
        _ serial: String,
        _ localPort: UInt16?,
        _ disconnectWifi: Bool,
        _ stopServer: Bool
    ) async -> Void

    @Published private(set) var engines: [DeviceSession] = []
    @Published var activeDeviceId: String?

    /// Serials awaiting user confirmation because a transfer is in progress.
    /// Set by `requestDisconnect`; cleared by confirm / cancel.
    @Published private(set) var pendingDisconnectSerials: [String] = []

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

    /// Last serial the user successfully opened a DroidMate session for.
    var lastConnectedSerial: String? {
        get { UserDefaults.standard.string(forKey: Self.lastConnectedSerialKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: Self.lastConnectedSerialKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastConnectedSerialKey)
            }
        }
    }

    /// Serials the user explicitly disconnected. ConnectionView must not
    /// auto-connect these while they remain visible in `adb devices`.
    /// Cleared when the user manually connects again, or when the serial
    /// disappears from a non-empty adb scan (true unplug / `adb disconnect`).
    private(set) var autoConnectSuppressed: Set<String> = []

    /// Wireless hosts (`192.168.x.x`) the user disconnected. Blocks auto-connect
    /// even if the connect port changes (common with Wireless debugging).
    private var autoConnectSuppressedHosts: Set<String> = []
    /// Last non-empty device scan supplied by ConnectionView. Disconnect
    /// grouping uses this cache and never shells out from the main actor.
    private var lastKnownAdbSerials: [String] = []
    private var isShuttingDown = false
    private var connectionTasks: [UUID: (serial: String, task: Task<Void, Error>)] = [:]
    private var connectionWorkflowTasks: [UUID: Task<Void, Never>] = [:]
    private var recoveryTasks: [String: (id: UUID, task: Task<Void, Error>)] = [:]
    private var cleanupTasks: [UUID: Task<Void, Never>] = [:]
    /// Wireless serials that finished `adb connect` before a DeviceSession exists.
    /// Quit must still `adb disconnect` these, or "connect then immediately quit"
    /// leaves orphan wireless adb sessions on the Mac.
    private var provisionalWirelessSerials: Set<String> = []
    private let cleanupOperation: CleanupOperation

    init(cleanupOperation: CleanupOperation? = nil) {
        self.cleanupOperation = cleanupOperation ?? { serial, localPort, disconnectWifi, stopServer in
            await Self.cleanupConnection(
                serial: serial,
                localPort: localPort,
                disconnectWifi: disconnectWifi,
                stopServer: stopServer
            )
        }
    }

    /// Owns a multi-step connection workflow that runs before `addDevice`
    /// (Wi-Fi connect/reconnect and USB→Wi-Fi). App teardown cancels and waits
    /// for every registered workflow before releasing adb resources.
    func startConnectionWorkflow(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        guard !isShuttingDown else { return }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.connectionWorkflowTasks.removeValue(forKey: id) }
            guard !Task.isCancelled else { return }
            await operation()
        }
        connectionWorkflowTasks[id] = task
    }

    /// Record a wireless adb serial that is live on this Mac but not yet in
    /// `engines`. Cleared when a session is created or the link is rolled back.
    func noteProvisionalWireless(_ serial: String) {
        guard serial.contains(":") else { return }
        provisionalWirelessSerials.insert(serial)
    }

    func clearProvisionalWireless(_ serial: String) {
        provisionalWirelessSerials.remove(serial)
    }

    /// Adds a new device: allocates a port, launches the Android server,
    /// creates a DeviceSession, and starts it. If this is the first device,
    /// it becomes active.
    ///
    /// `onStage` reports short localized progress strings for the connection UI.
    /// After each await, aborts if the serial was suppressed (user Disconnect mid-connect)
    /// or the task was cancelled.
    func addDevice(serial: String, onStage: ((String) -> Void)? = nil) async throws {
        guard !isShuttingDown else { throw CancellationError() }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performAddDevice(serial: serial, onStage: onStage)
        }
        connectionTasks[id] = (serial, task)
        defer { connectionTasks.removeValue(forKey: id) }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performAddDevice(serial: String, onStage: ((String) -> Void)?) async throws {
        // Manual (or intentional) connect — allow future auto-connect again.
        clearAutoConnectSuppression(for: serial)

        guard !engines.contains(where: { $0.deviceSerial == serial }) else {
            // Already connected — just switch to it.
            activeDeviceId = serial
            lastConnectedSerial = serial
            return
        }

        let port = nextLocalPort
        nextLocalPort &+= 1

        do {
            onStage?(String(localized: "Pushing server…"))
            try await Self.runAdbOperation {
                try ServerLauncher.shared.launchServer(serial: serial, localPort: port)
            }
            try throwIfConnectAborted(serial: serial)

            // Give the server a moment to bind before we connect.
            onStage?(String(localized: "Opening data channel…"))
            try await Task.sleep(for: .seconds(1))
            try throwIfConnectAborted(serial: serial)
        } catch {
            await cleanupOperation(serial, port, false, isShuttingDown)
            throw error
        }

        // Re-check pool after yield — another path may have connected the same serial.
        if engines.contains(where: { $0.deviceSerial == serial }) {
            await cleanupOperation(serial, port, false, false)
            activeDeviceId = serial
            lastConnectedSerial = serial
            return
        }

        let engine = DeviceSession(deviceSerial: serial, port: port)
        engine.onNeedsRecovery = { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.recover(serial: serial)
        }
        engines.append(engine)
        clearProvisionalWireless(serial)
        onStage?(String(localized: "Waiting for handshake…"))
        engine.start()
        // Always switch to the device we just connected (incl. "Add Device" flow).
        activeDeviceId = serial
        lastConnectedSerial = serial
    }

    /// User disconnected (or task cancelled) while `addDevice` was awaiting.
    private func throwIfConnectAborted(serial: String) throws {
        if Task.isCancelled || isShuttingDown {
            throw CancellationError()
        }
        // Disconnect suppresses the serial/host; do not append a session after that.
        guard shouldAutoConnect(serial: serial) else {
            throw CancellationError()
        }
    }

    func switchTo(_ serial: String) {
        guard engines.contains(where: { $0.deviceSerial == serial }) else { return }
        activeDeviceId = serial
        lastConnectedSerial = serial
    }

    /// Soft reconnect: re-open the local TCP socket only.
    func reconnect(_ serial: String) {
        guard let engine = engines.first(where: { $0.deviceSerial == serial }) else { return }
        engine.transport.reconnect()
    }

    /// Hard recover: re-assert wireless adb if needed, re-launch the on-device
    /// server, re-forward the port, then reconnect the data channel. Used when
    /// the socket fails for longer than a blip (server died, forward dropped).
    func recover(serial: String) async throws {
        guard !isShuttingDown else { throw CancellationError() }
        if let existing = recoveryTasks[serial] {
            try await withTaskCancellationHandler {
                try await existing.task.value
            } onCancel: {
                existing.task.cancel()
            }
            return
        }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performRecovery(serial: serial)
        }
        recoveryTasks[serial] = (id, task)
        defer {
            if recoveryTasks[serial]?.id == id {
                recoveryTasks.removeValue(forKey: serial)
            }
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performRecovery(serial: String) async throws {
        try Task.checkCancellation()
        // User already disconnected — never fight that with wireless reassert.
        guard shouldAutoConnect(serial: serial) else { return }
        guard let engine = engines.first(where: { $0.deviceSerial == serial }) else { return }
        guard recoveryCanContinue(engine) else { return }

        // Wireless endpoint may have dropped from adb while the Mac session stayed open.
        if serial.contains(":"), let ep = AdbBridge.WifiEndpoint.parse(serial) {
            engine.markRecovering(detail: String(localized: "Re-establishing wireless adb…"))
            do {
                _ = try await Self.runAdbOperation {
                    try AdbBridge.shared.connectWifi(ep)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                guard recoveryCanContinue(engine) else { return }
                engine.markRecovering(detail: String(localized: "Wireless adb reconnect failed — trying server relaunch…"))
            }
            try await Task.sleep(for: .milliseconds(400))
            guard recoveryCanContinue(engine) else { return }
        } else {
            engine.markRecovering(detail: String(localized: "Relaunching device server…"))
        }

        let present: [String]
        do {
            present = try await Self.runAdbOperation {
                try AdbBridge.shared.listDevices()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            present = []
        }
        try Task.checkCancellation()
        guard recoveryCanContinue(engine) else { return }
        let stillThere = present.contains(serial)
            || present.contains(where: { serial.hasPrefix($0 + ":") || $0.hasPrefix(serial) })
        guard stillThere else {
            engine.markRecoveryUnavailable(
                detail: String(localized: "Device not in adb devices — plug USB or re-pair Wi-Fi.")
            )
            return
        }

        do {
            engine.markRecovering(detail: String(localized: "Pushing server & opening tunnel…"))
            try await Self.runAdbOperation {
                try ServerLauncher.shared.launchServer(serial: serial, localPort: engine.port)
            }
            try Task.checkCancellation()
            guard !isShuttingDown,
                  stillOwns(engine),
                  shouldAutoConnect(serial: serial) else {
                await cleanupOperation(serial, engine.port, false, false)
                return
            }
            // A soft reconnect may have won while adb was running. Keep the
            // now-healthy forward intact and stop the hard-recovery pipeline.
            guard engine.transportState != .ready else { return }
            try await Task.sleep(for: .milliseconds(900))
            guard recoveryCanContinue(engine) else { return }
            engine.markRecovering(detail: String(localized: "Reopening data channel…"))
            engine.transport.reconnect()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard recoveryCanContinue(engine) else { return }
            // Last resort: socket-only reconnect (forward/server may still be up).
            engine.markRecovering(detail: String(localized: "Server launch failed — retrying socket…"))
            engine.transport.reconnect()
        }
    }

    // MARK: - Disconnect (with transfer guard)

    /// Whether any listed serial has an active transfer.
    func isTransferring(anyOf serials: [String]) -> Bool {
        for s in serials {
            if engines.first(where: { $0.deviceSerial == s })?.files.isTransferring == true {
                return true
            }
        }
        return false
    }

    /// Request disconnect. Expands to sibling USB/Wi-Fi serials of the same phone
    /// when known, then stages confirmation if any transfer is active.
    func requestDisconnect(_ serial: String) {
        requestDisconnect(serials: relatedSerials(for: serial))
    }

    /// Disconnect one or more related serials (USB + Wi-Fi of the same phone).
    func requestDisconnect(serials: [String]) {
        var expanded = Set<String>()
        for s in serials {
            for r in relatedSerials(for: s) { expanded.insert(r) }
        }
        let unique = expanded.sorted()
        guard !unique.isEmpty else { return }
        if isTransferring(anyOf: unique) {
            pendingDisconnectSerials = unique
            return
        }
        for s in unique {
            disconnect(s)
        }
    }

    /// Serials that should drop together: the given serial plus any live session
    /// or adb-visible peer sharing the same wireless host (USB↔Wi-Fi dual link).
    ///
    /// Uses **cached** USB IPs only (no shell on the main thread). Enrichment /
    /// prior `getDeviceIp` calls populate the cache.
    func relatedSerials(for serial: String) -> [String] {
        var set: Set<String> = [serial]
        let host = Self.wifiHost(of: serial)
        let present = lastKnownAdbSerials

        // Peer sessions already in the pool.
        for eng in engines {
            if eng.deviceSerial == serial { continue }
            if let host,
               let otherHost = Self.wifiHost(of: eng.deviceSerial),
               otherHost.caseInsensitiveCompare(host) == .orderedSame {
                set.insert(eng.deviceSerial)
            }
        }

        if serial.contains(":") {
            // Disconnecting Wi-Fi — also end USB session/cache match on same IP.
            if let host {
                for other in present where !other.contains(":") {
                    if let ip = AdbBridge.shared.cachedUsbIp(serial: other),
                       ip.caseInsensitiveCompare(host) == .orderedSame {
                        set.insert(other)
                    }
                }
                for eng in engines where !eng.deviceSerial.contains(":") {
                    if let ip = AdbBridge.shared.cachedUsbIp(serial: eng.deviceSerial),
                       ip.caseInsensitiveCompare(host) == .orderedSame {
                        set.insert(eng.deviceSerial)
                    }
                }
            }
        } else {
            // Disconnecting USB — also adb-disconnect matching wireless endpoints.
            if let ip = AdbBridge.shared.cachedUsbIp(serial: serial) {
                for other in present where other.contains(":") {
                    if let h = Self.wifiHost(of: other),
                       h.caseInsensitiveCompare(ip) == .orderedSame {
                        set.insert(other)
                    }
                }
                for eng in engines {
                    if let h = Self.wifiHost(of: eng.deviceSerial),
                       h.caseInsensitiveCompare(ip) == .orderedSame {
                        set.insert(eng.deviceSerial)
                    }
                }
            }
        }
        return Array(set)
    }

    func confirmPendingDisconnect() {
        let serials = pendingDisconnectSerials
        pendingDisconnectSerials = []
        for s in serials {
            disconnect(s)
        }
    }

    func cancelPendingDisconnect() {
        pendingDisconnectSerials = []
    }

    /// Disconnect a device from this Mac.
    ///
    /// - Always suppresses auto-connect for this serial / Wi-Fi host.
    /// - If a DroidMate session exists: stop it, drop port-forward, remove from pool.
    /// - If serial is wireless (`host:port`): also `adb disconnect` so it leaves
    ///   `adb devices` (works even when there is no DroidMate session yet —
    ///   connection-screen “Disconnect” on the left list).
    /// - USB without a session: no-op beyond suppress (cable stays physical).
    func disconnect(_ serial: String) {
        // Suppress first so recover / auto-connect cannot race a re-add.
        suppressAutoConnect(for: serial)
        provisionalWirelessSerials.remove(serial)
        connectionTasks.values
            .filter { $0.serial == serial }
            .forEach { $0.task.cancel() }
        recoveryTasks.removeValue(forKey: serial)?.task.cancel()
        var localPort: UInt16?

        if let idx = engines.firstIndex(where: { $0.deviceSerial == serial }) {
            let engine = engines[idx]
            localPort = engine.port
            engine.stop()
            engines.remove(at: idx)
            if activeDeviceId == serial {
                activeDeviceId = engines.first?.deviceSerial
            }
            NotificationCenter.default.post(name: .deviceSessionRemoved, object: serial)
        }

        // Drop wireless adb so the phone is fully offline from this Mac.
        let disconnectWifi = serial.contains(":")
        if localPort != nil || disconnectWifi {
            startCleanup(
                serial: serial,
                localPort: localPort,
                disconnectWifi: disconnectWifi,
                stopServer: false
            )
        }
        AdbBridge.shared.clearDeviceCaches(serial: serial)
    }

    /// Disconnects every device. Called on app teardown.
    func disconnectAll() async {
        isShuttingDown = true
        pendingDisconnectSerials = []
        let serials = engines.map(\.deviceSerial)
        let cleanups = engines.map { ($0.deviceSerial, $0.port, $0.deviceSerial.contains(":")) }
        // Snapshot pre-session wireless connects before cancelling workflows.
        let provisional = provisionalWirelessSerials
        provisionalWirelessSerials.removeAll()
        for engine in engines {
            suppressAutoConnect(for: engine.deviceSerial)
            engine.stop()
        }
        engines.removeAll()
        activeDeviceId = nil
        for serial in serials {
            NotificationCenter.default.post(name: .deviceSessionRemoved, object: serial)
        }

        let workflows = connectionWorkflowTasks
        let connections = connectionTasks.values.map(\.task)
        let recoveries = recoveryTasks.values.map(\.task)
        workflows.values.forEach { $0.cancel() }
        connections.forEach { $0.cancel() }
        recoveries.forEach { $0.cancel() }
        for (id, task) in workflows {
            await task.value
            connectionWorkflowTasks.removeValue(forKey: id)
        }
        for task in connections { _ = try? await task.value }
        for task in recoveries {
            do {
                try await task.value
            } catch is CancellationError {
                // Expected during teardown.
            } catch {
                // Recovery already surfaced operational failures in session state.
            }
        }

        // A normal Disconnect may already have removed its Device Session and
        // started adb cleanup. Drain those tasks before the app replies to Quit.
        while !cleanupTasks.isEmpty {
            let pending = cleanupTasks
            for (id, task) in pending {
                await task.value
                cleanupTasks.removeValue(forKey: id)
            }
        }

        var cleanedSerials = Set<String>()
        for (serial, port, disconnectWifi) in cleanups {
            await cleanupOperation(serial, port, disconnectWifi, true)
            cleanedSerials.insert(serial)
        }
        // Pre-session Wi-Fi (`adb connect` before DeviceSession) is not in
        // `engines`; still tear it down so Quit cannot leave orphan adb links.
        for serial in provisional where !cleanedSerials.contains(serial) {
            suppressAutoConnect(for: serial)
            await cleanupOperation(serial, nil, true, true)
        }
    }

    /// Drop suppression for serials no longer present in adb — a re-plug or
    /// fresh wireless connect should auto-connect again.
    ///
    /// Empty scans are ignored (adb glitches must not wipe suppression and
    /// immediately re-connect a just-disconnected Wi-Fi phone).
    func syncAutoConnectSuppression(withPresentSerials list: [String]) {
        guard !list.isEmpty else { return }
        lastKnownAdbSerials = list
        let present = Set(list)
        autoConnectSuppressed = autoConnectSuppressed.intersection(present)
        let presentHosts = Set(list.compactMap { Self.wifiHost(of: $0) })
        autoConnectSuppressedHosts = autoConnectSuppressedHosts.intersection(presentHosts)
    }

    /// Whether ConnectionView may auto-start a session for this serial.
    func shouldAutoConnect(serial: String) -> Bool {
        if isShuttingDown { return false }
        if autoConnectSuppressed.contains(serial) { return false }
        if let host = Self.wifiHost(of: serial), autoConnectSuppressedHosts.contains(host) {
            return false
        }
        return true
    }

    /// Prefer last-used serial, then USB, then first wireless — never a suppressed row.
    func preferredAutoConnectSerial(from list: [String]) -> String? {
        Self.pickAutoConnectSerial(
            from: list,
            lastConnected: lastConnectedSerial,
            shouldConnect: { shouldAutoConnect(serial: $0) }
        )
    }

    /// Pure picker for unit tests (nonisolated — no instance state).
    nonisolated static func pickAutoConnectSerial(
        from list: [String],
        lastConnected: String?,
        shouldConnect: (String) -> Bool
    ) -> String? {
        let candidates = list.filter(shouldConnect)
        guard !candidates.isEmpty else { return nil }
        if let last = lastConnected, candidates.contains(last) {
            return last
        }
        if let usb = candidates.first(where: { !$0.contains(":") }) {
            return usb
        }
        return candidates.first
    }

    // MARK: - Internals

    /// ADB is process-based and blocking. Keep it off the main actor; each
    /// operation called here also has a hard timeout in the wire/adb module.
    nonisolated static func runAdbOperation<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            task.cancel()
        }
    }

    private func startCleanup(
        serial: String,
        localPort: UInt16?,
        disconnectWifi: Bool,
        stopServer: Bool
    ) {
        let id = UUID()
        let operation = cleanupOperation
        let task = Task {
            await operation(serial, localPort, disconnectWifi, stopServer)
        }
        cleanupTasks[id] = task
        Task { [weak self] in
            await task.value
            self?.cleanupTasks.removeValue(forKey: id)
        }
    }

    nonisolated private static func cleanupConnection(
        serial: String,
        localPort: UInt16?,
        disconnectWifi: Bool,
        stopServer: Bool
    ) async {
        await Task.detached(priority: .utility) {
            if stopServer {
                try? ServerLauncher.shared.stopServer(serial: serial)
            }
            if let localPort {
                try? PortForwarder.shared.unforward(serial: serial, localPort: localPort)
            }
            if disconnectWifi {
                AdbBridge.shared.disconnectWifi(serial)
            }
        }.value
    }

    private func stillOwns(_ engine: DeviceSession) -> Bool {
        engines.contains(where: { $0 === engine })
    }

    private func recoveryCanContinue(_ engine: DeviceSession) -> Bool {
        !isShuttingDown
            && stillOwns(engine)
            && shouldAutoConnect(serial: engine.deviceSerial)
            && engine.transportState != .ready
    }

    private func suppressAutoConnect(for serial: String) {
        autoConnectSuppressed.insert(serial)
        if let host = Self.wifiHost(of: serial) {
            autoConnectSuppressedHosts.insert(host)
        }
    }

    private func clearAutoConnectSuppression(for serial: String) {
        autoConnectSuppressed.remove(serial)
        if let host = Self.wifiHost(of: serial) {
            autoConnectSuppressedHosts.remove(host)
        }
    }

    /// `host` part of a wireless `host:port` serial; nil for USB serials.
    private static func wifiHost(of serial: String) -> String? {
        guard serial.contains(":") else { return nil }
        return AdbBridge.WifiEndpoint.parse(serial)?.host
            ?? serial.split(separator: ":", maxSplits: 1).first.map(String.init)
    }
}
