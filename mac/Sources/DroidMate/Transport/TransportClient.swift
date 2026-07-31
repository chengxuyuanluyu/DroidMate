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
    private var inboundStream: AsyncStream<Frame>?
    private var inboundContinuation: AsyncStream<Frame>.Continuation?
    private var lastHost = "127.0.0.1"
    private var lastPort: UInt16 = 28042

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

    // MARK: - Handlers

    func setControlHandler(_ h: @escaping (Frame) async -> Void) { controlHandler = h }
    func setFilesHandler(_ h: @escaping (Frame) async -> Void)   { filesHandler = h }
    func setClipboardHandler(_ h: @escaping (Frame) async -> Void) { clipboardHandler = h }
    func setNotificationsHandler(_ h: @escaping (Frame) async -> Void) { notificationsHandler = h }

    // MARK: - Connect / disconnect

    func connect(host: String = "127.0.0.1", port: UInt16 = 28042) {
        guard connectionState == .disconnected || connectionState.isFailed else { return }
        connectionState = .connecting
        lastHost = host
        lastPort = port

        let params = NWParameters.tcp
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port)!,
                                using: params)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(state: state) }
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    func disconnect() {
        pingTimer?.cancel()
        pingTimer = nil
        connection?.cancel()
        connection = nil
        connectionState = .disconnected
        lastHelloAck = nil
    }

    // MARK: - State machine

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            connectionState = .handshaking
            log.info("socket ready, sending HELLO")
            sendHello()
            startReceiveLoop()
            startPingTimer()
        case .failed(let err):
            connectionState = .failed(err.localizedDescription)
            log.error("socket failed: \(err.localizedDescription, privacy: .public)")
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                if case .failed = connectionState { reconnect() }
            }
        case .cancelled:
            connectionState = .disconnected
            log.info("socket cancelled")
        default:
            break
        }
    }

    func reconnect() {
        pingTimer?.cancel()
        pingTimer = nil
        connection?.cancel()
        connection = nil
        connect(host: lastHost, port: lastPort)
    }

    // MARK: - Send path

    func send(_ frame: Data) async {
        guard let conn = connection else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            conn.send(content: frame, completion: .contentProcessed { _ in cont.resume() })
        }
    }

    private func sendHello() {
        Task {
            let hello = Hello(
                clientName: "DroidMate Mac 0.1",
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                capabilities: ["files"]
            )
            do {
                let bytes = try encodeJSONFrame(streamId: StreamId.control,
                                                msgType: MsgType.hello,
                                                payload: hello)
                await send(bytes)
            } catch {
                connectionState = .failed("hello encode failed: \(error)")
            }
        }
    }

    // MARK: - Receive loop

    private func startReceiveLoop() {
        // We read header-first (8 bytes), then payload, then loop.
        // NWConnection's receive(minIncompleteLength:maxLength:) lets us
        // enforce exact reads.
        Task { [weak self] in
            await self?.readLoop()
        }
    }

    private func readLoop() async {
        guard let conn = connection else { return }
        await readOne(connection: conn)
    }

    /// Reads one full frame and dispatches it. Re-arms after each frame.
    private func readOne(connection: NWConnection) async {
        // Read header
        let headerData = await readExact(connection: connection, count: FrameHeader.sizeBytes)
        guard let headerData else { return }  // cancelled / EOF

        let streamId   = readLE16(headerData, at: 0)
        let msgType    = readLE16(headerData, at: 2)
        let payloadLen = readLE32(headerData, at: 4)
        let len = Int(payloadLen)

        // Read payload
        var payload = Data()
        if len > 0 {
            guard let p = await readExact(connection: connection, count: len) else { return }
            payload = p
        }

        let frame = Frame(streamId: streamId, msgType: msgType, payload: payload)
        await dispatch(frame: frame)

        // Re-arm for next frame.
        await readOne(connection: connection)
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
            if let ack = try? WireJSON.decoder.decode(HelloAck.self, from: frame.payload) {
                lastHelloAck = ack
                connectionState = .ready
                log.info("HELLO_ACK: device=\(ack.deviceModel, privacy: .public) android=\(ack.androidVersion, privacy: .public) screen=\(ack.screenWidth)x\(ack.screenHeight) caps=\(ack.capabilities, privacy: .public)")
            }
        case MsgType.pong:
            if frame.payload.count >= 8 {
                let sent = readLE64(frame.payload, at: 0)
                let now = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
                roundTripNs = Int64(Int(now) - Int(sent))
            }
        case MsgType.error:
            if let err = try? WireJSON.decoder.decode(ErrorMsg.self, from: frame.payload) {
                connectionState = .failed("server: \(err.code) — \(err.message)")
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
                try? await Task.sleep(for: .seconds(2))
                await self?.sendPing()
            }
        }
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

    func sendClipboardSync(_ payload: ClipboardPayload) async {
        if let bytes = try? encodeJSONFrame(streamId: StreamId.clipboard,
                                            msgType: MsgType.clipboardSync,
                                            payload: payload) {
            await send(bytes)
        }
    }
}

extension TransportClient.ConnectionState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
