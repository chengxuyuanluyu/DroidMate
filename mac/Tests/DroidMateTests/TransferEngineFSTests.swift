import XCTest
@testable import DroidMate

/// S2: Transfer Engine FS mutation result handling (inbound completion).
@MainActor
final class TransferEngineFSTests: XCTestCase {

    func testDeleteResultResumesContinuation() async throws {
        let engine = TransferEngine()
        let result = FSDeleteResult(
            reqId: 42,
            results: [
                FSPathResult(path: "/sdcard/x", success: true, error: nil),
                FSPathResult(path: "/sdcard/y", success: false, error: "FILE_NOT_FOUND"),
            ]
        )
        let payload = try WireJSON.encoder.encode(result)
        let frame = Frame(streamId: StreamId.files, msgType: MsgType.fsDeleteResult, payload: payload)

        let got = await engine.withPendingDeleteForTesting(reqId: 42) {
            await engine.handleInboundForTesting(frame)
        }
        XCTAssertEqual(got, result.results)
    }

    func testRenameResultResumesContinuation() async throws {
        let engine = TransferEngine()
        let op = FSOpResult(reqId: 9, success: false, error: "FILE_NOT_FOUND")
        let payload = try WireJSON.encoder.encode(op)
        let frame = Frame(streamId: StreamId.files, msgType: MsgType.fsRenameResult, payload: payload)

        let got = await engine.withPendingOpForTesting(reqId: 9) {
            await engine.handleInboundForTesting(frame)
        }
        XCTAssertEqual(got, op)
    }

    func testDeleteWithoutTransportReturnsFailures() async {
        let engine = TransferEngine()
        let results = await engine.delete(paths: ["/a", "/b"])
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { !$0.success })
        XCTAssertEqual(results[0].error, "no transport")
    }

    func testRenameMkdirWithoutTransport() async {
        let engine = TransferEngine()
        let r = await engine.rename(from: "/a", to: "/b")
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.error, "no transport")
        let m = await engine.mkdir(path: "/c")
        XCTAssertFalse(m.success)
        XCTAssertEqual(m.error, "no transport")
    }
}
