import XCTest
@testable import DroidMate

final class WifiPasteTests: XCTestCase {
    func testFirstEndpointFromPlainAddress() {
        let ep = WifiPaste.firstEndpoint(in: "192.168.1.20:37123")
        XCTAssertEqual(ep?.host, "192.168.1.20")
        XCTAssertEqual(ep?.port, 37123)
    }

    func testFirstEndpointFromNoisyText() {
        let ep = WifiPaste.firstEndpoint(in: "IP address & port\n192.168.0.5:41234\nSomething else")
        XCTAssertEqual(ep?.display, "192.168.0.5:41234")
    }

    func testPairCodeExtraction() {
        XCTAssertEqual(WifiPaste.firstPairCode(in: "Wi‑Fi pairing code\n847291"), "847291")
        XCTAssertNil(WifiPaste.firstPairCode(in: "no code here 12345"))
    }

    func testPhoneRowsPreferOnlineOverRecent() {
        let online = ["192.168.1.8:5555"]
        let recent = [
            AdbBridge.WifiEndpoint(host: "192.168.1.8", port: 5555),
            AdbBridge.WifiEndpoint(host: "192.168.1.9", port: 37000),
        ]
        let rows = WifiPhoneRowModel.build(onlineSerials: online, recent: recent)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].isOnline)
        XCTAssertEqual(rows[0].title, "192.168.1.8:5555")
        XCTAssertFalse(rows[1].isOnline)
        XCTAssertEqual(rows[1].title, "192.168.1.9:37000")
    }
}

final class MdnsParseTests: XCTestCase {
    func testParseTlsConnectAndPairing() {
        let sample = """
        List of discovered mdns services
        adb-ABC123._adb-tls-connect._tcp.	192.168.1.42:41567
        adb-ABC123._adb-tls-pairing._tcp.	192.168.1.42:37123
        """
        let services = AdbBridge.parseMdnsServices(sample)
        XCTAssertEqual(services.count, 2)
        let connect = services.filter { $0.kind == .tlsConnect }
        XCTAssertEqual(connect.count, 1)
        XCTAssertEqual(connect.first?.endpoint.display, "192.168.1.42:41567")
        let pairing = services.filter { $0.kind == .tlsPairing }
        XCTAssertEqual(pairing.first?.endpoint.port, 37123)
    }

    func testParseIgnoresNoise() {
        let sample = """
        List of discovered mdns services
        (nothing here)
        some garbage line
        """
        XCTAssertTrue(AdbBridge.parseMdnsServices(sample).isEmpty)
    }

    func testParseSpaceSeparated() {
        let sample = "adb-R5C._adb-tls-connect._tcp 10.0.0.5:40675\n"
        let services = AdbBridge.parseMdnsServices(sample)
        XCTAssertEqual(services.count, 1)
        XCTAssertEqual(services[0].kind, .tlsConnect)
        XCTAssertEqual(services[0].endpoint.host, "10.0.0.5")
        XCTAssertEqual(services[0].endpoint.port, 40675)
    }
}
