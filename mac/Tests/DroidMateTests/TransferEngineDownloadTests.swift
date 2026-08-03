import XCTest
@testable import DroidMate

@MainActor
final class TransferEngineDownloadTests: XCTestCase {

    func testSameDestinationCannotBeClaimedByTwoSessions() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("shared.bin")

        let first = try XCTUnwrap(TransferEngine.claimDownloadDestination(destination))
        XCTAssertNil(TransferEngine.claimDownloadDestination(destination))
        TransferEngine.releaseDownloadDestination(first)

        let retry = try XCTUnwrap(TransferEngine.claimDownloadDestination(destination))
        TransferEngine.releaseDownloadDestination(retry)
    }

    func testExplicitCancellationCanBeConsumedOnce() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("cancelled.bin")
        let engine = TransferEngine()

        let succeeded = await engine.withPendingDownloadForTesting(
            reqId: 13,
            localURL: destination,
            entry: entry(name: destination.lastPathComponent, size: 1)
        ) {
            engine.cancelTransfer(13)
        }

        XCTAssertFalse(succeeded)
        XCTAssertTrue(engine.consumeExplicitDownloadCancellation(for: destination))
        XCTAssertFalse(engine.consumeExplicitDownloadCancellation(for: destination))
    }

    func testCompleteDownloadReplacesExistingFile() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("photo.bin")
        try Data("old".utf8).write(to: destination)
        let bytes = Data("new payload".utf8)
        let engine = TransferEngine()

        let succeeded = await engine.withPendingDownloadForTesting(
            reqId: 7,
            localURL: destination,
            entry: entry(name: destination.lastPathComponent, size: bytes.count)
        ) {
            await engine.handleInboundForTesting(self.downloadStart(reqId: 7, size: bytes.count))
            await engine.handleInboundForTesting(self.downloadData(reqId: 7, offset: 0, bytes: bytes))
            await engine.handleInboundForTesting(self.downloadComplete(reqId: 7, success: true))
        }

        XCTAssertTrue(succeeded)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathExtension("droidmate-partial").path
        ))
    }

    func testUnexpectedDownloadOffsetFailsWithoutReplacingDestination() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("photo.bin")
        let original = Data("keep me".utf8)
        try original.write(to: destination)
        let bytes = Data("payload".utf8)
        let engine = TransferEngine()

        let succeeded = await engine.withPendingDownloadForTesting(
            reqId: 8,
            localURL: destination,
            entry: entry(name: destination.lastPathComponent, size: bytes.count)
        ) {
            await engine.handleInboundForTesting(self.downloadStart(reqId: 8, size: bytes.count))
            await engine.handleInboundForTesting(self.downloadData(reqId: 8, offset: 1, bytes: bytes))
        }

        XCTAssertFalse(succeeded)
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testTruncatedDownloadFrameFailsInsteadOfLeavingWaiterPending() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("photo.bin")
        let engine = TransferEngine()
        var payload = Data()
        appendLE32(11, to: &payload)

        let succeeded = await engine.withPendingDownloadForTesting(
            reqId: 11,
            localURL: destination,
            entry: entry(name: destination.lastPathComponent, size: 1)
        ) {
            await engine.handleInboundForTesting(
                Frame(streamId: StreamId.files, msgType: MsgType.downloadData, payload: payload)
            )
        }

        XCTAssertFalse(succeeded)
    }

    func testResumeRequiresAndAppendsAtExpectedOffset() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("video.bin")
        let partial = destination.appendingPathExtension("droidmate-partial")
        try Data("abc".utf8).write(to: partial)
        let suffix = Data("def".utf8)
        let engine = TransferEngine()

        let succeeded = await engine.withPendingDownloadForTesting(
            reqId: 9,
            localURL: destination,
            entry: entry(name: destination.lastPathComponent, size: 6),
            startOffset: 3
        ) {
            await engine.handleInboundForTesting(self.downloadStart(reqId: 9, size: 6, offset: 3))
            await engine.handleInboundForTesting(self.downloadData(reqId: 9, offset: 3, bytes: suffix))
            await engine.handleInboundForTesting(self.downloadComplete(reqId: 9, success: true))
        }

        XCTAssertTrue(succeeded)
        XCTAssertEqual(try Data(contentsOf: destination), Data("abcdef".utf8))
    }

    func testCommitFailureLeavesExistingDestinationIntact() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("document.bin")
        let original = Data("original".utf8)
        let replacement = Data("replacement".utf8)
        try original.write(to: destination)
        let partial = destination.appendingPathExtension("droidmate-partial")
        let engine = TransferEngine()

        let succeeded = await engine.withPendingDownloadForTesting(
            reqId: 10,
            localURL: destination,
            entry: entry(name: destination.lastPathComponent, size: replacement.count)
        ) {
            await engine.handleInboundForTesting(self.downloadStart(reqId: 10, size: replacement.count))
            await engine.handleInboundForTesting(self.downloadData(reqId: 10, offset: 0, bytes: replacement))
            try? FileManager.default.removeItem(at: partial)
            await engine.handleInboundForTesting(self.downloadComplete(reqId: 10, success: true))
        }

        XCTAssertFalse(succeeded)
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testChangedRemoteRevisionDiscardsExistingPartial() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let partial = dir.appendingPathComponent("video.bin.droidmate-partial")
        let engine = TransferEngine()
        let original = entry(name: "video.bin", size: 10, modified: 1)

        XCTAssertEqual(
            engine.prepareDownloadOffsetForTesting(
                partialURL: partial,
                remotePath: "/sdcard/video.bin",
                entry: original
            ),
            0
        )
        try Data("abc".utf8).write(to: partial)
        XCTAssertEqual(
            engine.prepareDownloadOffsetForTesting(
                partialURL: partial,
                remotePath: "/sdcard/video.bin",
                entry: original
            ),
            3
        )

        let changed = entry(name: "video.bin", size: 10, modified: 2)
        XCTAssertEqual(
            engine.prepareDownloadOffsetForTesting(
                partialURL: partial,
                remotePath: "/sdcard/video.bin",
                entry: changed
            ),
            0
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testDownloadInactivityTimeoutResumesWaiter() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("stalled.bin")
        let engine = TransferEngine(downloadInactivityTimeout: .milliseconds(30))

        let succeeded = await engine.withPendingDownloadForTesting(
            reqId: 12,
            localURL: destination,
            entry: entry(name: destination.lastPathComponent, size: 1),
            background: false
        ) {}

        XCTAssertFalse(succeeded)
        XCTAssertEqual(engine.transferHistory.first?.status, .failed)
    }

    func testDownloadStartRejectsChangedRemoteRevision() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("changed.bin")
        let engine = TransferEngine()

        let succeeded = await engine.withPendingDownloadForTesting(
            reqId: 14,
            localURL: destination,
            entry: entry(name: destination.lastPathComponent, size: 4, modified: 1)
        ) {
            await engine.handleInboundForTesting(
                self.downloadStart(reqId: 14, size: 4, modified: 2_000)
            )
        }

        XCTAssertFalse(succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroidMateDownloadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entry(name: String, size: Int, modified: TimeInterval = 0) -> DirEntry {
        DirEntry(
            id: name,
            name: name,
            size: Int64(size),
            modified: Date(timeIntervalSince1970: modified),
            isDir: false,
            mime: "application/octet-stream",
            sizeText: "\(size)",
            dateText: ""
        )
    }

    private func downloadData(reqId: Int, offset: UInt64, bytes: Data) -> Frame {
        var payload = Data()
        appendLE32(UInt32(reqId), to: &payload)
        appendLE64(offset, to: &payload)
        appendLE32(UInt32(bytes.count), to: &payload)
        payload.append(bytes)
        return Frame(streamId: StreamId.files, msgType: MsgType.downloadData, payload: payload)
    }

    private func downloadStart(
        reqId: Int,
        size: Int,
        modified: Int64 = 0,
        offset: Int64 = 0
    ) -> Frame {
        let payload = try! JSONSerialization.data(withJSONObject: [
            "req_id": reqId,
            "size": size,
            "modified": modified,
            "offset": offset,
        ])
        return Frame(streamId: StreamId.files, msgType: MsgType.downloadStart, payload: payload)
    }

    private func downloadComplete(reqId: Int, success: Bool) -> Frame {
        let payload = try! JSONSerialization.data(withJSONObject: ["req_id": reqId, "success": success])
        return Frame(streamId: StreamId.files, msgType: MsgType.downloadComplete, payload: payload)
    }

    private func appendLE32(_ value: UInt32, to data: inout Data) {
        var value = value
        for _ in 0..<4 {
            data.append(UInt8(value & 0xff))
            value >>= 8
        }
    }

    private func appendLE64(_ value: UInt64, to data: inout Data) {
        var value = value
        for _ in 0..<8 {
            data.append(UInt8(value & 0xff))
            value >>= 8
        }
    }
}
