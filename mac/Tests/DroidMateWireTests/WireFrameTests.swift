import XCTest
import DroidMateWire

final class WireFrameTests: XCTestCase {

    func testEncodeEmptyFrameHeader() {
        let frame = encodeFrame(streamId: 0x0001, msgType: 0x0002, payload: Data())
        XCTAssertEqual(frame.count, 8)
        let expected: [UInt8] = [0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(Array(frame), expected)
    }

    func testRoundTrip() {
        let payload = Data("hello".utf8)
        let original = encodeFrame(streamId: StreamId.files, msgType: MsgType.listDir, payload: payload)
        var buf = original
        let frames = FrameParser.parse(from: &buf)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].streamId, StreamId.files)
        XCTAssertEqual(frames[0].msgType, MsgType.listDir)
        XCTAssertEqual(frames[0].payload, payload)
        XCTAssertTrue(buf.isEmpty)
    }

    func testStreamIdsStable() {
        XCTAssertEqual(StreamId.control, 0x0000)
        XCTAssertEqual(StreamId.files, 0x0003)
        XCTAssertEqual(MsgType.dirEntry, 0x0301)
        XCTAssertEqual(MsgType.fsCopy, 0x0336)
    }

    func testAdbShellEscape() {
        XCTAssertEqual(AdbRunner.shellEscape("a"), "'a'")
        XCTAssertEqual(AdbRunner.shellEscape("a'b"), "'a'\\''b'")
    }

    func testPortForwarderRemotePort() {
        XCTAssertEqual(PortForwarder.remotePort, 28042)
    }
}
