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
