import Foundation
import Network
import os

private let log = Logger(subsystem: "com.droidmate", category: "TransportClient")

/// Asynchronous client for the DroidMate wire protocol.
///
/// Owns one `NWConnection` to localhost:PORT. Sends framed messages on the
/// connection, dispatches inbound frames to handlers keyed by stream id.
/// Reconnect-with-backoff is built in for USB cable flakiness.
///
/// Concurrency model: each NWConnection dispatches its own queue. We bridge
/// to the Swift Concurrency world by `Continuation`-wrapping the
/// `send`/`receive` callbacks. Inbound frames are pulled via an infinite
/// `receiveMessage` loop that delivers `Frame`s on an `AsyncStream`.
@MainActor
final class TransportClient: ObservableObject {

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var lastHelloAck: HelloAck?
    @Published private(set) var roundTripNs: Int64 = 0

    private var connection: NWConnection?
    private var pingTimer: Task<Void, Never>?
    private var handshakeTimeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var inboundStream: AsyncStream<Frame>?
    private var inboundContinuation: AsyncStream<Frame>.Continuation?
    private var lastHost = "127.0.0.1"
    private var lastPort: UInt16 = 28042
    private let handshakeTimeout: Duration
    private let sendTimeout: Duration

    // Per-connection dispatch table. Set by callers via `setHandler`.
    private var controlHandler: ((Frame) async -> Void)?
    private var filesHandler:   ((Frame) async -> Void)?
    private var clipboardHandler: ((Frame) async -> Void)?
    private var notificationsHandler: ((Frame) async -> Void)?

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case handshaking
        case ready
        case failed(String)
    }

    init(
        handshakeTimeout: Duration = .seconds(5),
        sendTimeout: Duration = .seconds(10)
    ) {
        self.handshakeTimeout = handshakeTimeout
        self.sendTimeout = sendTimeout
    }

    // MARK: - Handlers

    func setControlHandler(_ h: @escaping (Frame) async -> Void) { controlHandler = h }
    func setFilesHandler(_ h: @escaping (Frame) async -> Void)   { filesHandler = h }
    func setClipboardHandler(_ h: @escaping (Frame) async -> Void) { clipboardHandler = h }
    func setNotificationsHandler(_ h: @escaping (Frame) async -> Void) { notificationsHandler = h }

    // MARK: - Connect / disconnect

    func connect(host: String = "127.0.0.1", port: UInt16 = 28042) {
        guard connectionState == .disconnected || connectionState.isFailed else { return }
        connectionState = .connecting
        lastHelloAck = nil
        lastHost = host
        lastPort = port

        let params = NWParameters.tcp
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port)!,
                                using: params)
        connection = conn

        // Ignore state updates from a cancelled / superseded connection.
        // Without this, cancel() often surfaces as `.failed`, which used to
        // auto-reconnect and fight intentional disconnect (especially Wi-Fi).
        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.connection === conn else { return }
                    self.handle(state: state)
                }
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    func disconnect() {
        stopConnectionTasks()
        // Drop the reference first so a late NWConnection callback cannot
        // re-enter handle() / schedule soft reconnect.
        let conn = connection
        connection = nil
        connectionState = .disconnected
        lastHelloAck = nil
        conn?.cancel()
    }

    // MARK: - State machine

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            connectionState = .handshaking
            log.info("socket ready, sending HELLO")
            startHandshakeTimeout(for: connection)
            sendHello(on: connection)
            startReceiveLoop(for: connection)
        case .waiting(let err), .failed(let err):
            let conn = connection
            stopConnectionTasks()
            connection = nil
            connectionState = .failed(err.localizedDescription)
            conn?.cancel()
            log.error("socket unavailable: \(err.localizedDescription, privacy: .public)")
            // Soft reconnect only while this connection is still current.
            reconnectTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(800))
                } catch {
                    return
                }
                guard let self else { return }
                guard case .failed = self.connectionState else { return }
                // Still the live client (not replaced / torn down).
                self.reconnect()
            }
        case .cancelled:
            connectionState = .disconnected
            log.info("socket cancelled")
        default:
            break
        }
    }

    func reconnect() {
        stopConnectionTasks()
        let conn = connection
        connection = nil
        conn?.cancel()
        connect(host: lastHost, port: lastPort)
    }

    // MARK: - Send path

    @discardableResult
    func send(_ frame: Data) async -> Bool {
        guard connectionState == .ready, let conn = connection else { return false }
        return await send(frame, on: conn) && connectionState == .ready
    }

    private func send(_ frame: Data, on conn: NWConnection) async -> Bool {
        guard connection === conn else { return false }
        let timeout = sendTimeout
        let accepted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let result = SendResult(cont)
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                result.resolve(false)
            }
            result.setTimeoutTask(timeoutTask)
            conn.send(content: frame, completion: .contentProcessed { error in
                result.resolve(error == nil)
            })
        }
        guard accepted else {
            fail(connection: conn, message: "send failed or timed out")
            return false
        }
        return connection === conn
    }

    private func sendHello(on conn: NWConnection?) {
        guard let conn else { return }
        Task { [weak self] in
            guard let self, self.connection === conn else { return }
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                ?? "development"
            let hello = Hello(
                clientName: "DroidMate Mac \(version)",
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                capabilities: ["files"]
            )
            do {
                let bytes = try encodeJSONFrame(streamId: StreamId.control,
                                                msgType: MsgType.hello,
                                                payload: hello)
                guard await self.send(bytes, on: conn) else {
                    self.fail(connection: conn, message: "HELLO send failed")
                    return
                }
            } catch {
                self.fail(connection: conn, message: "HELLO encode failed: \(error)")
            }
        }
    }

    private func startHandshakeTimeout(for conn: NWConnection?) {
        guard let conn else { return }
        handshakeTimeoutTask?.cancel()
        let timeout = handshakeTimeout
        handshakeTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard let self,
                  self.connection === conn,
                  self.connectionState == .handshaking else { return }
            self.fail(connection: conn, message: "HELLO_ACK timed out")
        }
    }

    // MARK: - Receive loop

    private func startReceiveLoop(for conn: NWConnection?) {
        guard let conn else { return }
        // We read header-first (8 bytes), then payload, then loop.
        // NWConnection's receive(minIncompleteLength:maxLength:) lets us
        // enforce exact reads.
        Task { [weak self] in
            await self?.readLoop(connection: conn)
        }
    }

    private func readLoop(connection conn: NWConnection) async {
        guard connection === conn else { return }
        while connection === conn {
            guard let headerData = await readExact(connection: conn, count: FrameHeader.sizeBytes) else {
                if connection === conn, !connectionState.isFailed {
                    let message = connectionState == .handshaking
                        ? "connection closed during handshake"
                        : "connection closed by server"
                    fail(connection: conn, message: message)
                }
                return
            }
            guard connection === conn else { return }

            let streamId = readLE16(headerData, at: 0)
            let msgType = readLE16(headerData, at: 2)
            let len = Int(readLE32(headerData, at: 4))
            guard len < FrameHeader.maxPayload else {
                fail(connection: conn, message: "frame payload too large: \(len) bytes")
                return
            }

            let payload: Data
            if len > 0 {
                guard let data = await readExact(connection: conn, count: len) else {
                    if connection === conn, !connectionState.isFailed {
                        fail(connection: conn, message: "connection closed during frame payload")
                    }
                    return
                }
                guard connection === conn else { return }
                payload = data
            } else {
                payload = Data()
            }
            await dispatch(frame: Frame(streamId: streamId, msgType: msgType, payload: payload))
        }
    }

    private func fail(connection conn: NWConnection, message: String) {
        guard connection === conn else { return }
        stopConnectionTasks()
        connectionState = .failed(message)
        connection = nil
        conn.cancel()
        log.error("protocol failure: \(message, privacy: .public)")
    }

    /// Reads exactly `count` bytes from a connection by accumulating chunks.
    private func readExact(connection: NWConnection, count: Int) async -> Data? {
        var buf = Data(capacity: count)
        while buf.count < count {
            let need = count - buf.count
            let chunk: Data? = await withCheckedContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: need) { data, _, _, error in
                    if let data = data, !data.isEmpty, error == nil {
                        cont.resume(returning: data)
                    } else {
                        cont.resume(returning: nil)
                    }
                }
            }
            guard let chunk else { return nil }
            buf.append(chunk)
        }
        return buf
    }

    // MARK: - Dispatch

    private func dispatch(frame: Frame) async {
        log.debug("← stream=0x\(frame.streamId, format: .hex) msg=0x\(frame.msgType, format: .hex) len=\(frame.payload.count)")
        guard connectionState == .ready || frame.streamId == StreamId.control else {
            log.warning("dropping pre-handshake frame on stream 0x\(frame.streamId, format: .hex)")
            return
        }
        switch frame.streamId {
        case StreamId.control: await handleControl(frame)
        case StreamId.files:   await filesHandler?(frame)
        case StreamId.clipboard: await clipboardHandler?(frame)
        case StreamId.notifications: await notificationsHandler?(frame)
        default:
            log.warning("unknown stream 0x\(frame.streamId, format: .hex)")
        }
    }

    private func handleControl(_ frame: Frame) async {
        switch frame.msgType {
        case MsgType.helloAck:
            guard connectionState == .handshaking, let conn = connection else { return }
            let ack: HelloAck
            do {
                ack = try WireJSON.decoder.decode(HelloAck.self, from: frame.payload)
            } catch {
                fail(connection: conn, message: "invalid HELLO_ACK: \(error)")
                return
            }
            guard ack.protocolVersion == Hello.currentProtocolVersion else {
                fail(
                    connection: conn,
                    message: "unsupported protocol version \(ack.protocolVersion) (expected \(Hello.currentProtocolVersion))"
                )
                return
            }
            guard ack.capabilities.contains("files") else {
                fail(connection: conn, message: "server does not support files capability")
                return
            }
            handshakeTimeoutTask?.cancel()
            handshakeTimeoutTask = nil
            lastHelloAck = ack
            connectionState = .ready
            startPingTimer()
            log.info("HELLO_ACK: device=\(ack.deviceModel, privacy: .public) android=\(ack.androidVersion, privacy: .public) screen=\(ack.screenWidth)x\(ack.screenHeight) caps=\(ack.capabilities, privacy: .public)")
        case MsgType.pong:
            if frame.payload.count >= 8 {
                let sent = readLE64(frame.payload, at: 0)
                let now = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
                roundTripNs = Int64(Int(now) - Int(sent))
            }
        case MsgType.error:
            if let err = try? WireJSON.decoder.decode(ErrorMsg.self, from: frame.payload) {
                if let conn = connection {
                    fail(connection: conn, message: "server: \(err.code) — \(err.message)")
                }
                log.error("server error: \(err.code, privacy: .public) — \(err.message, privacy: .public)")
            }
        default:
            await controlHandler?(frame)
        }
    }

    // MARK: - Ping

    private func startPingTimer() {
        pingTimer?.cancel()
        pingTimer = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                await self?.sendPing()
            }
        }
    }

    private func stopConnectionTasks() {
        pingTimer?.cancel()
        pingTimer = nil
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func sendPing() async {
        var ts = UInt64(Date().timeIntervalSince1970 * 1_000_000_000).littleEndian
        let data = withUnsafeBytes(of: &ts) { Data($0) }
        let frame = encodeFrame(streamId: StreamId.control,
                                msgType: MsgType.ping,
                                payload: data)
        await send(frame)
    }

    func triggerPingForTesting() async {
        await sendPing()
    }

    // MARK: - Public send helpers

    @discardableResult
    func sendClipboardSync(_ payload: ClipboardPayload) async -> Bool {
        if let bytes = try? encodeJSONFrame(streamId: StreamId.clipboard,
                                            msgType: MsgType.clipboardSync,
                                            payload: payload) {
            return await send(bytes)
        }
        return false
    }
}

final class SendResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        let alreadyResolved = continuation == nil
        if !alreadyResolved { timeoutTask = task }
        lock.unlock()
        if alreadyResolved { task.cancel() }
    }

    func resolve(_ value: Bool) {
        lock.lock()
        let continuation = self.continuation
        let timeoutTask = self.timeoutTask
        self.continuation = nil
        self.timeoutTask = nil
        lock.unlock()
        timeoutTask?.cancel()
        continuation?.resume(returning: value)
    }
}

extension TransportClient.ConnectionState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
