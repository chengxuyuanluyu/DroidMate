import XCTest
import Network
import Darwin
import Combine
@testable import DroidMate

@MainActor
final class TCPSyncTests: XCTestCase {

    func testHandshakeCompletes() throws {
        let server = RawTcpServer()
        let port = try server.start()
        XCTAssertTrue(port > 0)

        let client = TransportClient()
        client.connect(host: "127.0.0.1", port: port)

        let readyExp = expectation(description: "ready")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            let done = MainActor.assumeIsolated { client.connectionState == .ready }
            if done { t.invalidate(); readyExp.fulfill() }
        }
        RunLoop.main.add(timer, forMode: .common)
        wait(for: [readyExp], timeout: 5.0)

        XCTAssertEqual(client.connectionState, .ready)
        XCTAssertEqual(client.lastHelloAck?.serverName, "MockAndroid")
        XCTAssertEqual(client.lastHelloAck?.screenWidth, 1080)

        client.disconnect()
        server.stop()
    }

    func testSendWithoutConnectionReportsFailure() async {
        let client = TransportClient()
        let sent = await client.send(Data([0x01]))
        XCTAssertFalse(sent)
    }

    func testOversizedFrameIsRejectedBeforePayloadRead() async throws {
        let server = RawTcpServer(sendOversizedFrameAfterHello: true)
        let port = try server.start()
        let client = TransportClient()
        client.connect(host: "127.0.0.1", port: port)

        for _ in 0..<100 {
            if case .failed = client.connectionState { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        guard case .failed(let message) = client.connectionState else {
            XCTFail("expected protocol failure, got \(client.connectionState)")
            client.disconnect()
            server.stop()
            return
        }
        XCTAssertTrue(message.contains("payload too large"))
        client.disconnect()
        server.stop()
    }

    func testHandshakeRejectsUnsupportedProtocolVersion() async throws {
        let server = RawTcpServer(protocolVersion: Hello.currentProtocolVersion + 1)
        let port = try server.start()
        let client = TransportClient()
        defer {
            client.disconnect()
            server.stop()
        }

        client.connect(host: "127.0.0.1", port: port)
        let message = try await waitForFailure(client)

        XCTAssertTrue(message.contains("unsupported protocol version"))
        XCTAssertNil(client.lastHelloAck)
    }

    func testHandshakeRequiresFilesCapability() async throws {
        let server = RawTcpServer(capabilities: ["clipboard", "notifications"])
        let port = try server.start()
        let client = TransportClient()
        defer {
            client.disconnect()
            server.stop()
        }

        client.connect(host: "127.0.0.1", port: port)
        let message = try await waitForFailure(client)

        XCTAssertTrue(message.contains("files capability"))
        XCTAssertNil(client.lastHelloAck)
    }

    func testHandshakeTimesOutWhenServerDoesNotAcknowledge() async throws {
        let server = RawTcpServer(respondToHello: false)
        let port = try server.start()
        let client = TransportClient(handshakeTimeout: .milliseconds(150))
        defer {
            client.disconnect()
            server.stop()
        }

        client.connect(host: "127.0.0.1", port: port)
        let message = try await waitForFailure(client)

        XCTAssertEqual(message, "HELLO_ACK timed out")
    }

    func testServerCloseAfterHandshakeBecomesFailure() async throws {
        let server = RawTcpServer(closeAfterHelloAck: true)
        let port = try server.start()
        let client = TransportClient()
        defer {
            client.disconnect()
            server.stop()
        }

        client.connect(host: "127.0.0.1", port: port)
        let message = try await waitForFailure(client)

        XCTAssertEqual(client.lastHelloAck?.serverName, "MockAndroid")
        XCTAssertTrue(message.contains("connection closed"))
    }

    func testUnavailablePortDoesNotStayConnecting() async throws {
        let server = RawTcpServer()
        let port = try server.start()
        server.stop()
        let client = TransportClient()
        defer { client.disconnect() }

        client.connect(host: "127.0.0.1", port: port)
        let message = try await waitForFailure(client)

        XCTAssertFalse(message.isEmpty)
    }

    func testBusinessSendIsRejectedBeforeHandshakeCompletes() async throws {
        let server = RawTcpServer(respondToHello: false)
        let port = try server.start()
        let client = TransportClient(handshakeTimeout: .seconds(2))
        defer {
            client.disconnect()
            server.stop()
        }

        client.connect(host: "127.0.0.1", port: port)
        for _ in 0..<100 {
            if client.connectionState == .handshaking { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(client.connectionState, .handshaking)

        let sent = await client.send(
            encodeFrame(streamId: StreamId.files, msgType: MsgType.listDir, payload: Data())
        )
        XCTAssertFalse(sent)
    }

    func testSendResultTimeoutResumesOnce() async {
        let value = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let result = SendResult(cont)
            let timeout = Task {
                try? await Task.sleep(for: .milliseconds(20))
                result.resolve(false)
            }
            result.setTimeoutTask(timeout)
        }
        XCTAssertFalse(value)
    }

    func testSendResultIgnoresLateCompletion() async {
        let value = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let result = SendResult(cont)
            let timeout = Task {
                try? await Task.sleep(for: .seconds(1))
                result.resolve(false)
            }
            result.setTimeoutTask(timeout)
            result.resolve(true)
            result.resolve(false)
        }
        XCTAssertTrue(value)
    }

    func testSynchronousPublishedCancellationSuppressesDownloadStart() async throws {
        let server = RawTcpServer()
        let port = try server.start()
        let client = TransportClient()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroidMateCancelBeforeStart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            client.disconnect()
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        client.connect(host: "127.0.0.1", port: port)
        try await waitForReady(client)

        let engine = TransferEngine()
        engine.bind(transport: client)
        let destination = directory.appendingPathComponent("cancelled.bin")
        let entry = DirEntry(
            id: "cancelled.bin",
            name: "cancelled.bin",
            size: 1,
            modified: .distantPast,
            isDir: false,
            mime: "application/octet-stream",
            sizeText: "1 byte",
            dateText: ""
        )
        var cancellation: AnyCancellable?
        cancellation = engine.$transfers.dropFirst().sink { transfers in
            guard let reqId = transfers.first?.id else { return }
            engine.cancelTransfer(reqId)
        }

        let succeeded = await engine.download(
            remotePath: "/sdcard/cancelled.bin",
            to: destination,
            entry: entry
        )
        cancellation?.cancel()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(succeeded)
        XCTAssertFalse(server.recordedFileMessageTypes().contains(MsgType.downloadStart))
    }

    func testDownloadCancelFollowsStartOnWire() async throws {
        let server = RawTcpServer()
        let port = try server.start()
        let client = TransportClient()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroidMateCancelAfterStart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            client.disconnect()
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        client.connect(host: "127.0.0.1", port: port)
        try await waitForReady(client)

        let engine = TransferEngine()
        engine.bind(transport: client)
        let destination = directory.appendingPathComponent("started.bin")
        let entry = DirEntry(
            id: "started.bin",
            name: "started.bin",
            size: 1,
            modified: .distantPast,
            isDir: false,
            mime: "application/octet-stream",
            sizeText: "1 byte",
            dateText: ""
        )
        let download = Task {
            await engine.download(
                remotePath: "/sdcard/started.bin",
                to: destination,
                entry: entry
            )
        }

        for _ in 0..<100 {
            if server.recordedFileMessageTypes().contains(MsgType.downloadStart) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(server.recordedFileMessageTypes().contains(MsgType.downloadStart))
        let reqId = try XCTUnwrap(engine.transfers.first?.id)
        engine.cancelTransfer(reqId)
        let succeeded = await download.value
        XCTAssertFalse(succeeded)

        for _ in 0..<100 {
            if server.recordedFileMessageTypes().contains(MsgType.downloadCancel) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let downloadMessages = server.recordedFileMessageTypes().filter {
            $0 == MsgType.downloadStart || $0 == MsgType.downloadCancel
        }
        XCTAssertEqual(downloadMessages, [MsgType.downloadStart, MsgType.downloadCancel])
    }

    private func waitForFailure(_ client: TransportClient) async throws -> String {
        for _ in 0..<100 {
            if case .failed(let message) = client.connectionState {
                return message
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(
            domain: "TCPSyncTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "expected failure, got \(client.connectionState)"]
        )
    }

    private func waitForReady(_ client: TransportClient) async throws {
        for _ in 0..<100 {
            if client.connectionState == .ready { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(
            domain: "TCPSyncTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "expected ready, got \(client.connectionState)"]
        )
    }
}

private final class RawTcpServer {
    private var listenFd: Int32 = -1
    private var clientFd: Int32 = -1
    private let queue = DispatchQueue(label: "raw-tcp", qos: .userInitiated)
    private let sendOversizedFrameAfterHello: Bool
    private let protocolVersion: Int
    private let capabilities: [String]
    private let respondToHello: Bool
    private let closeAfterHelloAck: Bool
    private let messageLock = NSLock()
    private var fileMessageTypes: [UInt16] = []

    init(
        sendOversizedFrameAfterHello: Bool = false,
        protocolVersion: Int = Hello.currentProtocolVersion,
        capabilities: [String] = ["files"],
        respondToHello: Bool = true,
        closeAfterHelloAck: Bool = false
    ) {
        self.sendOversizedFrameAfterHello = sendOversizedFrameAfterHello
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.respondToHello = respondToHello
        self.closeAfterHelloAck = closeAfterHelloAck
    }

    func start() throws -> UInt16 {
        listenFd = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFd >= 0 else { throw NSError(domain: "socket", code: -1) }
        var on: Int32 = 1
        setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw NSError(domain: "bind", code: Int(Darwin.errno)) }
        guard Darwin.listen(listenFd, 1) == 0 else {
            throw NSError(domain: "listen", code: Int(Darwin.errno))
        }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenFd, $0, &len)
            }
        }
        let port = UInt16(bigEndian: actual.sin_port)
        queue.async { [weak self] in self?.acceptLoop() }
        return port
    }

    func stop() {
        if clientFd >= 0 { shutdown(clientFd, Int32(SHUT_RDWR)); close(clientFd); clientFd = -1 }
        if listenFd >= 0 { shutdown(listenFd, Int32(SHUT_RDWR)); close(listenFd); listenFd = -1 }
    }

    func recordedFileMessageTypes() -> [UInt16] {
        messageLock.lock()
        defer { messageLock.unlock() }
        return fileMessageTypes
    }

    private func acceptLoop() {
        let fd = accept(listenFd, nil, nil)
        guard fd >= 0 else { return }
        clientFd = fd
        serve(fd: fd)
    }

    private func serve(fd: Int32) {
        while true {
            var hdr = [UInt8](repeating: 0, count: 8)
            guard readN(fd: fd, buf: &hdr, count: 8) else { return }
            let mt = UInt16(hdr[2]) | (UInt16(hdr[3]) << 8)
            let stream = UInt16(hdr[0]) | (UInt16(hdr[1]) << 8)
            let plen = UInt32(hdr[4]) | (UInt32(hdr[5]) << 8) |
                       (UInt32(hdr[6]) << 16) | (UInt32(hdr[7]) << 24)
            var payload = [UInt8](repeating: 0, count: Int(plen))
            if plen > 0 { guard readN(fd: fd, buf: &payload, count: Int(plen)) else { return } }

            if stream == StreamId.files {
                messageLock.lock()
                fileMessageTypes.append(mt)
                messageLock.unlock()
            }

            switch mt {
            case 0x0001:
                guard respondToHello else { continue }
                let ack = HelloAck(
                    protocolVersion: protocolVersion,
                    serverName: "MockAndroid",
                    deviceModel: "T",
                    androidVersion: "17",
                    screenWidth: 1080,
                    screenHeight: 2400,
                    screenDpi: 480,
                    capabilities: capabilities,
                    supportedEncoders: [],
                    isRooted: false
                )
                guard let frame = try? encodeJSONFrame(
                    streamId: StreamId.control,
                    msgType: MsgType.helloAck,
                    payload: ack
                ) else { return }
                _ = frame.withUnsafeBytes { bytes in
                    Darwin.write(fd, bytes.baseAddress!, bytes.count)
                }
                if closeAfterHelloAck {
                    shutdown(fd, Int32(SHUT_RDWR))
                    return
                }
                if sendOversizedFrameAfterHello {
                    let oversized = UInt32(FrameHeader.maxPayload)
                    let header: [UInt8] = [
                        0x01, 0x00, 0x20, 0x00,
                        UInt8(oversized & 0xFF), UInt8((oversized >> 8) & 0xFF),
                        UInt8((oversized >> 16) & 0xFF), UInt8((oversized >> 24) & 0xFF),
                    ]
                    _ = header.withUnsafeBufferPointer { write(fd, $0.baseAddress!, $0.count) }
                }
            case 0x0010:
                var f = [UInt8]()
                f += [0x00, 0x00, 0x11, 0x00]
                f += [UInt8(plen & 0xFF), UInt8((plen>>8)&0xFF), UInt8((plen>>16)&0xFF), UInt8((plen>>24)&0xFF)]
                f += payload
                _ = f.withUnsafeBufferPointer { write(fd, $0.baseAddress!, $0.count) }
            default: break
            }
        }
    }

    private func readN(fd: Int32, buf: inout [UInt8], count: Int) -> Bool {
        var off = 0
        while off < count {
            let n = buf.withUnsafeMutableBufferPointer { p in
                Darwin.read(fd, p.baseAddress! + off, count - off)
            }
            if n <= 0 { return false }
            off += n
        }
        return true
    }
}
