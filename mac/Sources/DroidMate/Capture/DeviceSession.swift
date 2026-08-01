import Foundation
import SwiftUI
import Combine
import os

private let engineLog = Logger(subsystem: "com.droidmate", category: "DeviceSession")

@MainActor
final class DeviceSession: ObservableObject {

    enum RecoveryPhase: Equatable {
        case idle
        /// Soft/hard recovery in progress (server relaunch / wifi reassert).
        case recovering(attempt: Int, detail: String)
        /// Exhausted auto-retries; user should reconnect manually.
        case gaveUp(String)
    }

    @Published var transportState: TransportClient.ConnectionState = .disconnected
    @Published var ack: HelloAck?
    @Published var rttMs: Double = 0
    @Published private(set) var recoveryPhase: RecoveryPhase = .idle

    let deviceSerial: String
    let port: UInt16
    let transport = TransportClient()
    let files = FileClient()
    let clipboard = ClipboardBridge()
    let notifications = NotificationBridge()

    /// Called when transport stays failed long enough that a hard recovery
    /// (re-launch server / re-assert wireless adb) is warranted.
    var onNeedsRecovery: (() async throws -> Void)?

    private var bag: Set<AnyCancellable> = []
    private var recoveryTask: Task<Void, Never>?
    private var recoveryAttempts = 0
    private let maxRecoveryAttempts = 5
    private let recoveryDelayOverride: Duration?

    /// Friendly label for sidebar / menus: model when known, else serial.
    var displayName: String {
        if let model = ack?.deviceModel, !model.isEmpty { return model }
        return deviceSerial
    }

    /// USB vs Wi-Fi — serial contains `host:port` after wireless adb connect.
    var isWireless: Bool { deviceSerial.contains(":") }

    var transportLabel: String {
        isWireless ? String(localized: "Wi-Fi") : String(localized: "USB")
    }

    /// Ready for file ops (HELLO_ACK received, transport up).
    var isSessionReady: Bool {
        ack != nil && transportState == .ready
    }

    init(deviceSerial: String, port: UInt16, recoveryDelay: Duration? = nil) {
        self.deviceSerial = deviceSerial
        self.port = port
        self.recoveryDelayOverride = recoveryDelay
        files.deviceSerial = deviceSerial
    }

    func start(host: String = "127.0.0.1") {
        transport.setControlHandler { [weak self] frame in
            await self?.handleControl(frame)
        }
        files.bind(transport: transport)
        clipboard.bind(transport: transport)
        clipboard.start()
        notifications.bind(transport: transport)

        transport.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleTransportState(state)
            }
            .store(in: &bag)

        transport.$lastHelloAck
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ack in
                guard let self else { return }
                self.ack = ack
                if let ack, self.transportState != .ready {
                    self.handleTransportState(.ready)
                    engineLog.info("HELLO_ACK \(ack.deviceModel, privacy: .public) \(ack.screenWidth)x\(ack.screenHeight)")
                }
            }
            .store(in: &bag)

        transport.$roundTripNs
            .receive(on: DispatchQueue.main)
            .map { Double($0) / 1_000_000 }
            .assign(to: \.rttMs, on: self)
            .store(in: &bag)

        transport.connect(host: host, port: port)
    }

    func stop() {
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryAttempts = 0
        onNeedsRecovery = nil
        recoveryPhase = .idle
        // Detach observers before tearing down the socket so a late
        // `.failed` cannot schedule recovery after intentional disconnect.
        bag.removeAll()
        files.handleTransportInterruption(reason: String(localized: "Disconnected"))
        clipboard.stop()
        transport.disconnect()
    }

    /// User-visible detail while ConnectionManager runs hard recovery.
    func markRecovering(detail: String) {
        // A late adb completion must not replace the healthy UI after the
        // Data Channel has already recovered.
        guard transportState != .ready else { return }
        // Manual reconnect after give-up: allow auto-recovery attempts again.
        if case .gaveUp = recoveryPhase {
            recoveryAttempts = 0
        }
        recoveryPhase = .recovering(attempt: max(recoveryAttempts, 1), detail: detail)
    }

    func markRecoveryUnavailable(detail: String) {
        guard transportState != .ready else { return }
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryPhase = .gaveUp(detail)
    }

    /// After the soft socket reconnect fails to restore readiness, escalate to
    /// a hard recover (adb + server relaunch) with backoff.
    private func scheduleRecovery(lastError: String) {
        // Keep the first pending deadline. TransportClient may emit a new
        // `.failed` every 800 ms while it soft-reconnects; restarting this
        // longer timer on every failure can prevent hard recovery forever.
        guard recoveryTask == nil else { return }
        guard recoveryAttempts < maxRecoveryAttempts else {
            let hint = isWireless
                ? String(localized: "Wi-Fi link may be down. Reconnect wireless adb or plug in USB.")
                : String(localized: "Check the USB cable and that USB debugging is still allowed.")
            recoveryPhase = .gaveUp(String(localized: "Couldn’t restore connection. \(hint)"))
            engineLog.error("recovery gave up for \(self.deviceSerial, privacy: .public): \(lastError, privacy: .public)")
            return
        }
        let attempt = recoveryAttempts + 1
        let delay = recoveryDelayOverride
            ?? .milliseconds(UInt64(min(1_200 * attempt, 6_000)))
        let kind = isWireless ? String(localized: "Wi-Fi") : String(localized: "USB")
        recoveryPhase = .recovering(
            attempt: attempt,
            detail: String(localized: "Reconnecting (\(kind), try \(attempt)/\(maxRecoveryAttempts))…")
        )
        recoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self else { return }
            // Soft reconnect may already have fixed it.
            guard case .failed = self.transportState else {
                self.recoveryTask = nil
                return
            }
            guard let onNeedsRecovery = self.onNeedsRecovery else {
                self.recoveryTask = nil
                return
            }
            self.recoveryAttempts = attempt
            engineLog.info("auto-recover attempt \(attempt) for \(self.deviceSerial, privacy: .public)")
            // Keep this task installed for the full hard-recovery attempt so
            // repeated transport failures cannot start overlapping relaunches.
            do {
                try await onNeedsRecovery()
            } catch is CancellationError {
                // If another waiter cancelled the shared hard-recovery task,
                // this Device Session itself may still be failed and active.
                // Release the completed task so the next backoff can proceed.
                guard !Task.isCancelled else { return }
                self.recoveryTask = nil
                if case .failed(let message) = self.transportState {
                    self.scheduleRecovery(lastError: message)
                }
                return
            } catch {
                engineLog.error("hard recovery failed for \(self.deviceSerial, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            guard !Task.isCancelled else { return }
            self.recoveryTask = nil
            if case .failed(let message) = self.transportState {
                self.scheduleRecovery(lastError: message)
            }
        }
    }

    /// Applies one Transport state transition. Internal so the recovery timing
    /// contract can be exercised without opening a real socket.
    func handleTransportState(_ state: TransportClient.ConnectionState) {
        transportState = state
        switch state {
        case .ready:
            recoveryAttempts = 0
            recoveryTask?.cancel()
            recoveryTask = nil
            recoveryPhase = .idle
        case .failed(let msg):
            files.handleTransportInterruption(reason: msg)
            if case .gaveUp = recoveryPhase { break }
            scheduleRecovery(lastError: msg)
        default:
            break
        }
    }

    private func handleControl(_ frame: Frame) async {
        guard frame.msgType == MsgType.error else { return }
        if let err = try? WireJSON.decoder.decode(ErrorMsg.self, from: frame.payload) {
            engineLog.error("server error \(err.code, privacy: .public): \(err.message, privacy: .public)")
        }
    }
}
