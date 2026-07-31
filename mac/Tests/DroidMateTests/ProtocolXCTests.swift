import XCTest
@testable import DroidMate

/// All protocol-layer tests consolidated under XCTest.
/// swift-testing crashes on Xcode 26.6 (signal 5), so we use XCTest which
/// works reliably.
@MainActor
final class ProtocolXCTests: XCTestCase {

    // MARK: - Frame Codec

    func testEmptyPayloadHeader() {
        let frame = encodeFrame(streamId: 0x0001, msgType: 0x0002, payload: Data())
        XCTAssertEqual(frame.count, 8)
        let expected: [UInt8] = [0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(Array(frame), expected)
    }

    func testFrameWithPayloadPreservesLEHeader() {
        let payload = Data([0xAA, 0xBB, 0xCC])
        let frame = encodeFrame(streamId: 0x1234, msgType: 0x5678, payload: payload)
        let expected: [UInt8] = [0x34, 0x12, 0x78, 0x56, 0x03, 0x00, 0x00, 0x00, 0xAA, 0xBB, 0xCC]
        XCTAssertEqual(Array(frame), expected)
    }

    func testFrameRoundTrip() {
        let payload = Data("hello".utf8)
        let original = encodeFrame(streamId: 0x0001, msgType: 0x0100, payload: payload)
        var buf = original
        let frames = FrameParser.parse(from: &buf)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].streamId, 0x0001)
        XCTAssertEqual(frames[0].msgType, 0x0100)
        XCTAssertEqual(frames[0].payload, payload)
        XCTAssertTrue(buf.isEmpty)
    }

    func testPartialHeaderBuffered() {
        var buf = Data([0x01, 0x00, 0x02])
        let frames = FrameParser.parse(from: &buf)
        XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(buf.count, 3)
    }

    func testPartialPayloadBuffered() {
        var buf = Data([0x01, 0x00, 0x00, 0x01, 0x04, 0x00, 0x00, 0x00, 0xAA, 0xBB])
        let frames = FrameParser.parse(from: &buf)
        XCTAssertTrue(frames.isEmpty)
    }

    func testMultipleFramesInOneBuffer() {
        var buf = encodeFrame(streamId: 0x0001, msgType: 0x0010, payload: Data([0x01]))
        buf.append(encodeFrame(streamId: 0x0002, msgType: 0x0020, payload: Data([0x02, 0x03])))
        let frames = FrameParser.parse(from: &buf)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].streamId, 0x0001)
        XCTAssertEqual(frames[1].payload, Data([0x02, 0x03]))
    }

    func testOversizedPayloadRejected() {
        var buf = Data([0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01])
        let frames = FrameParser.parse(from: &buf)
        XCTAssertTrue(frames.isEmpty)
    }

    // MARK: - JSON Coding

    func testHelloEncodesSnakeCase() throws {
        let h = Hello(protocolVersion: 0, clientName: "DroidMate Mac 0.1",
                      osVersion: "macOS 27", capabilities: ["h265", "files"])
        let data = try WireJSON.encoder.encode(h)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"protocol_version\":0"))
        XCTAssertTrue(json.contains("\"client_name\":\"DroidMate Mac 0.1\""))
        XCTAssertTrue(json.contains("\"os_version\":\"macOS 27\""))
    }

    func testHelloAckDecodes() throws {
        let json = """
        {"protocol_version":0,"server_name":"MockAndroid","device_model":"Pixel 9",
         "android_version":"17","screen_width":1080,"screen_height":2400,"screen_dpi":480,
         "capabilities":["h265"],"supported_encoders":["h265"],"is_rooted":false}
        """
        let ack = try WireJSON.decoder.decode(HelloAck.self, from: Data(json.utf8))
        XCTAssertEqual(ack.serverName, "MockAndroid")
        XCTAssertEqual(ack.screenWidth, 1080)
        XCTAssertEqual(ack.screenHeight, 2400)
        XCTAssertFalse(ack.isRooted)
    }

    func testHelloAckForwardCompat() throws {
        let json = """
        {"protocol_version":0,"server_name":"x","device_model":"x","android_version":"x",
         "screen_width":1,"screen_height":1,"screen_dpi":1,"capabilities":[],
         "supported_encoders":[],"is_rooted":false,"future_field":42}
        """
        let ack = try WireJSON.decoder.decode(HelloAck.self, from: Data(json.utf8))
        XCTAssertEqual(ack.serverName, "x")
    }

    func testErrorMsgRoundTrip() throws {
        let original = ErrorMsg(code: "PROJECTION_REVOKED", message: "user revoked")
        let data = try WireJSON.encoder.encode(original)
        let decoded = try WireJSON.decoder.decode(ErrorMsg.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testEncodeJSONFrameWrapsHeader() throws {
        let hello = Hello(clientName: "t", osVersion: "t", capabilities: [])
        let frame = try encodeJSONFrame(streamId: StreamId.control,
                                        msgType: MsgType.hello, payload: hello)
        XCTAssertGreaterThanOrEqual(frame.count, 8)
        XCTAssertEqual(readLE16(frame, at: 0), 0)
        XCTAssertEqual(readLE16(frame, at: 2), 1)
        XCTAssertEqual(Int(readLE32(frame, at: 4)), frame.count - 8)
    }

    // MARK: - Clipboard Payload (M6a)

    func testClipboardPayloadRoundTrip() throws {
        let original = ClipboardPayload(
            ts: 1_700_000_000_000,
            source: "mac",
            mime: "text/plain",
            text: "hello 安卓 \n emoji 🚀"
        )
        let data = try WireJSON.encoder.encode(original)
        let decoded = try WireJSON.decoder.decode(ClipboardPayload.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testClipboardPayloadWireKeysAreSnakeCase() throws {
        // PROTOCOL.md §7.1: wire keys are ts / source / mime / text.
        let payload = ClipboardPayload(ts: 1, source: "mac", mime: "text/plain", text: "x")
        let data = try WireJSON.encoder.encode(payload)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"ts\"") == false)
        XCTAssertTrue(json.contains("\"source\""))
        XCTAssertTrue(json.contains("\"mime\""))
        XCTAssertTrue(json.contains("\"text\""))
        XCTAssertTrue(json.contains("\"mac\""))
    }

    func testClipboardPayloadEmptyTextRoundTrips() throws {
        // §7.2: empty text means "clipboard cleared" — must round-trip cleanly.
        let original = ClipboardPayload(ts: 0, source: "android", mime: "text/plain", text: "")
        let data = try WireJSON.encoder.encode(original)
        let decoded = try WireJSON.decoder.decode(ClipboardPayload.self, from: data)
        XCTAssertEqual(decoded.text, "")
    }

    func testClipboardFrameEncodeUsesCorrectStreamAndMsg() throws {
        let payload = ClipboardPayload(ts: 1, source: "mac", mime: "text/plain", text: "abc")
        let frame = try encodeJSONFrame(streamId: StreamId.clipboard,
                                        msgType: MsgType.clipboardSync, payload: payload)
        XCTAssertEqual(readLE16(frame, at: 0), 0x0004)
        XCTAssertEqual(readLE16(frame, at: 2), 0x0400)
    }

    // MARK: - Notification Payloads (M6b)

    func testNotificationAddedRoundTrip() throws {
        let original = NotificationAddedPayload(
            ts: 1_700_000_000_000,
            key: "0|com.example.app|42|tag1|10042",
            package: "com.example.app",
            id: 42,
            tag: "tag1",
            title: "New message",
            text: "Hey 你好 🚀",
            category: "msg"
        )
        let data = try WireJSON.encoder.encode(original)
        let decoded = try WireJSON.decoder.decode(NotificationAddedPayload.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testNotificationAddedWithNilOptionals() throws {
        let original = NotificationAddedPayload(
            ts: 0, key: "k", package: "p", id: 0, tag: nil,
            title: "t", text: "", category: nil
        )
        let data = try WireJSON.encoder.encode(original)
        let decoded = try WireJSON.decoder.decode(NotificationAddedPayload.self, from: data)
        XCTAssertNil(decoded.tag)
        XCTAssertNil(decoded.category)
        XCTAssertEqual(decoded.text, "")
    }

    func testNotificationRemovedRoundTrip() throws {
        let original = NotificationRemovedPayload(ts: 1, key: "0|x|1|null|2", reason: "unknown")
        let data = try WireJSON.encoder.encode(original)
        let decoded = try WireJSON.decoder.decode(NotificationRemovedPayload.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testNotificationAddedFrameUsesCorrectStreamAndMsg() throws {
        let payload = NotificationAddedPayload(
            ts: 1, key: "k", package: "p", id: 1, tag: nil,
            title: "t", text: "x", category: nil
        )
        let frame = try encodeJSONFrame(streamId: StreamId.notifications,
                                        msgType: MsgType.notificationAdded, payload: payload)
        XCTAssertEqual(readLE16(frame, at: 0), 0x0005)
        XCTAssertEqual(readLE16(frame, at: 2), 0x0500)
    }

    // MARK: - FS Mutations (foundation ticket 03)

    func testFSDeleteRequestWireKeys() throws {
        let req = FSDeleteRequest(reqId: 7, paths: ["/sdcard/a", "/sdcard/b"])
        let data = try WireJSON.encoder.encode(req)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"req_id\":7"), json)
        XCTAssertTrue(json.contains("\"paths\""), json)
        // JSONEncoder may escape slashes as \/
        XCTAssertTrue(json.contains("sdcard"), json)
        let decoded = try WireJSON.decoder.decode(FSDeleteRequest.self, from: data)
        XCTAssertEqual(decoded.paths, ["/sdcard/a", "/sdcard/b"])
    }

    func testFSDeleteResultRoundTrip() throws {
        let original = FSDeleteResult(
            reqId: 3,
            results: [
                FSPathResult(path: "/sdcard/a", success: true, error: nil),
                FSPathResult(path: "/sdcard/b", success: false, error: "FILE_NOT_FOUND"),
            ]
        )
        let data = try WireJSON.encoder.encode(original)
        let decoded = try WireJSON.decoder.decode(FSDeleteResult.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testFSRenameMkdirCopyRoundTrip() throws {
        let rename = FSRenameRequest(reqId: 1, from: "/sdcard/a", to: "/sdcard/b")
        let renameData = try WireJSON.encoder.encode(rename)
        XCTAssertEqual(try WireJSON.decoder.decode(FSRenameRequest.self, from: renameData), rename)

        let mkdir = FSMkdirRequest(reqId: 2, path: "/sdcard/New")
        let mkdirData = try WireJSON.encoder.encode(mkdir)
        XCTAssertEqual(try WireJSON.decoder.decode(FSMkdirRequest.self, from: mkdirData), mkdir)

        let copy = FSCopyRequest(reqId: 3, from: "Download/a", to: "Download/b")
        let copyData = try WireJSON.encoder.encode(copy)
        XCTAssertEqual(try WireJSON.decoder.decode(FSCopyRequest.self, from: copyData), copy)
        XCTAssertTrue(String(data: copyData, encoding: .utf8)!.contains("\"req_id\":3"))

        let op = FSOpResult(reqId: 2, success: false, error: "FILE_EXISTS")
        let opData = try WireJSON.encoder.encode(op)
        XCTAssertEqual(try WireJSON.decoder.decode(FSOpResult.self, from: opData), op)
    }

    func testFSMutationFrameMsgTypes() throws {
        let del = try encodeJSONFrame(
            streamId: StreamId.files,
            msgType: MsgType.fsDelete,
            payload: FSDeleteRequest(reqId: 1, paths: ["/x"])
        )
        XCTAssertEqual(readLE16(del, at: 0), StreamId.files)
        XCTAssertEqual(readLE16(del, at: 2), 0x0330)

        let ren = try encodeJSONFrame(
            streamId: StreamId.files,
            msgType: MsgType.fsRenameResult,
            payload: FSOpResult(reqId: 1, success: true, error: nil)
        )
        XCTAssertEqual(readLE16(ren, at: 2), 0x0333)

        let mk = try encodeJSONFrame(
            streamId: StreamId.files,
            msgType: MsgType.fsMkdir,
            payload: FSMkdirRequest(reqId: 1, path: "/y")
        )
        XCTAssertEqual(readLE16(mk, at: 2), 0x0334)

        let cp = try encodeJSONFrame(
            streamId: StreamId.files,
            msgType: MsgType.fsCopy,
            payload: FSCopyRequest(reqId: 1, from: "a", to: "b")
        )
        XCTAssertEqual(readLE16(cp, at: 2), 0x0336)
    }

    func testHelloAckDecodesWithoutEncoders() throws {
        let json = """
        {"protocol_version":0,"server_name":"S","device_model":"M","android_version":"14",\
        "screen_width":1080,"screen_height":2400,"screen_dpi":480,\
        "capabilities":["files","clipboard","notifications"],"is_rooted":false}
        """.replacingOccurrences(of: "\\\n", with: "")
        let data = Data(json.utf8)
        let ack = try WireJSON.decoder.decode(HelloAck.self, from: data)
        XCTAssertEqual(ack.capabilities, ["files", "clipboard", "notifications"])
        XCTAssertEqual(ack.supportedEncoders, [])
    }
}
