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
    var onNeedsRecovery: (() -> Void)?

    private var bag: Set<AnyCancellable> = []
    private var recoveryTask: Task<Void, Never>?
    private var recoveryAttempts = 0
    private let maxRecoveryAttempts = 5

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

    init(deviceSerial: String, port: UInt16) {
        self.deviceSerial = deviceSerial
        self.port = port
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
                guard let self else { return }
                self.transportState = state
                switch state {
                case .ready:
                    self.recoveryAttempts = 0
                    self.recoveryTask?.cancel()
                    self.recoveryTask = nil
                    self.recoveryPhase = .idle
                case .failed(let msg):
                    if case .gaveUp = self.recoveryPhase { break }
                    self.scheduleRecovery(lastError: msg)
                default:
                    break
                }
            }
            .store(in: &bag)

        transport.$lastHelloAck
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ack in
                guard let self else { return }
                self.ack = ack
                if let ack, self.transportState != .ready {
                    self.transportState = .ready
                    self.recoveryAttempts = 0
                    self.recoveryPhase = .idle
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
        onNeedsRecovery = nil
        recoveryPhase = .idle
        clipboard.stop()
        transport.disconnect()
        bag.removeAll()
    }

    /// User-visible detail while ConnectionManager runs hard recovery.
    func markRecovering(detail: String) {
        // Manual reconnect after give-up: allow auto-recovery attempts again.
        if case .gaveUp = recoveryPhase {
            recoveryAttempts = 0
        }
        recoveryPhase = .recovering(attempt: max(recoveryAttempts, 1), detail: detail)
    }

    /// After the soft socket reconnect fails to restore readiness, escalate to
    /// a hard recover (adb + server relaunch) with backoff.
    private func scheduleRecovery(lastError: String) {
        recoveryTask?.cancel()
        guard recoveryAttempts < maxRecoveryAttempts else {
            let hint = isWireless
                ? String(localized: "Wi-Fi link may be down. Reconnect wireless adb or plug in USB.")
                : String(localized: "Check the USB cable and that USB debugging is still allowed.")
            recoveryPhase = .gaveUp(String(localized: "Couldn’t restore connection. \(hint)"))
            engineLog.error("recovery gave up for \(self.deviceSerial, privacy: .public): \(lastError, privacy: .public)")
            return
        }
        recoveryAttempts += 1
        let attempt = recoveryAttempts
        let delayMs = UInt64(min(1_200 * attempt, 6_000))
        let kind = isWireless ? String(localized: "Wi-Fi") : String(localized: "USB")
        recoveryPhase = .recovering(
            attempt: attempt,
            detail: String(localized: "Reconnecting (\(kind), try \(attempt)/\(maxRecoveryAttempts))…")
        )
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard let self, !Task.isCancelled else { return }
            // Soft reconnect may already have fixed it.
            if case .failed = self.transportState {
                engineLog.info("auto-recover attempt \(attempt) for \(self.deviceSerial, privacy: .public)")
                self.onNeedsRecovery?()
            }
        }
    }

    private func handleControl(_ frame: Frame) async {
        guard frame.msgType == MsgType.error else { return }
        if let err = try? WireJSON.decoder.decode(ErrorMsg.self, from: frame.payload) {
            engineLog.error("server error \(err.code, privacy: .public): \(err.message, privacy: .public)")
        }
    }
}
