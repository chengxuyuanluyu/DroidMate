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

    func testAdbRunnerDrainsLargeBinaryOutput() throws {
        let data = try AdbRunner.runData(
            "/bin/dd",
            args: ["if=/dev/zero", "bs=1024", "count=256"],
            timeout: 2
        )

        XCTAssertEqual(data.count, 256 * 1024)
    }

    func testAdbRunnerReportsStderrWithoutMixingStdout() throws {
        XCTAssertThrowsError(
            try AdbRunner.run(
                "/bin/sh",
                args: ["-c", "printf stdout; printf stderr >&2; exit 7"],
                timeout: 2
            )
        ) { error in
            guard case let AdbError.commandFailed(status, stderr) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(status, 7)
            XCTAssertEqual(stderr, "stderr")
        }
    }

    func testAdbRunnerStopsTimedOutProcess() throws {
        let started = Date()

        XCTAssertThrowsError(
            try AdbRunner.run("/bin/sleep", args: ["2"], timeout: 0.05)
        ) { error in
            guard case let AdbError.timedOut(seconds) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(seconds, 0.05, accuracy: 0.001)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testAdbRunnerChecksCancellationBeforeLaunching() async {
        let task = Task {
            try withUnsafeCurrentTask { current in
                current?.cancel()
                return try AdbRunner.run(
                    "/definitely/missing/droidmate-test-executable",
                    args: [],
                    timeout: 1
                )
            }
        }

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: the missing executable must never be launched.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testPortForwarderRemotePort() {
        XCTAssertEqual(PortForwarder.remotePort, 28042)
    }
}
