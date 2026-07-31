import XCTest
import Network
import Darwin
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
}

private final class RawTcpServer {
    private var listenFd: Int32 = -1
    private var clientFd: Int32 = -1
    private let queue = DispatchQueue(label: "raw-tcp", qos: .userInitiated)

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
            let plen = UInt32(hdr[4]) | (UInt32(hdr[5]) << 8) |
                       (UInt32(hdr[6]) << 16) | (UInt32(hdr[7]) << 24)
            var payload = [UInt8](repeating: 0, count: Int(plen))
            if plen > 0 { guard readN(fd: fd, buf: &payload, count: Int(plen)) else { return } }

            switch mt {
            case 0x0001:
                let json = #"{"protocol_version":0,"server_name":"MockAndroid","device_model":"T","android_version":"17","screen_width":1080,"screen_height":2400,"screen_dpi":480,"capabilities":["h265"],"supported_encoders":["h265"],"is_rooted":false}"#
                let bytes = Array(json.utf8)
                let l = UInt32(bytes.count)
                var f = [UInt8]()
                f += [0x00, 0x00, 0x02, 0x00]
                f += [UInt8(l & 0xFF), UInt8((l>>8)&0xFF), UInt8((l>>16)&0xFF), UInt8((l>>24)&0xFF)]
                f += bytes
                _ = f.withUnsafeBufferPointer { write(fd, $0.baseAddress!, $0.count) }
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
