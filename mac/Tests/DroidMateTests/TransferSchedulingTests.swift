import XCTest
@testable import DroidMate

/// S2: transfer concurrency bounds and background yield to foreground work.
@MainActor
final class TransferSchedulingTests: XCTestCase {

    func testMaxConcurrentConstant() {
        XCTAssertEqual(TransferEngine.maxConcurrentFileTransfers, 4)
        XCTAssertGreaterThan(TransferEngine.maxConcurrentFileTransfers, 0)
    }

    func testRunBoundedAggregatesResults() async {
        let allOk = await TransferEngine.runBounded(Array(0..<10), limit: 3) { _ in true }
        XCTAssertTrue(allOk)

        let failed = await TransferEngine.runBounded([1, 2, 3], limit: 2) { n in
            n != 2
        }
        XCTAssertFalse(failed)
    }

    func testRunBoundedEmptyIsSuccess() async {
        let ok = await TransferEngine.runBounded([Int](), limit: 4) { _ in false }
        XCTAssertTrue(ok)
    }

    func testRunBoundedProcessesEveryItem() async {
        final class Counter: @unchecked Sendable {
            private var n = 0
            func inc() { n += 1 }
            var value: Int { n }
        }
        let counter = Counter()
        _ = await TransferEngine.runBounded(Array(0..<7), limit: 2) { _ in
            counter.inc()
            return true
        }
        XCTAssertEqual(counter.value, 7)
    }

    func testBackgroundDownloadYieldsToForeground() async {
        let engine = TransferEngine()
        engine.setForegroundCountForTesting(1)

        var finished = false
        let task = Task { @MainActor in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                engine.setForegroundCountForTesting(0)
            }
            let entry = DirEntry(
                id: "x.bin",
                name: "x.bin",
                size: 1,
                modified: Date(timeIntervalSince1970: 0),
                isDir: false,
                mime: "application/octet-stream",
                sizeText: "1 B",
                dateText: "—"
            )
            _ = await engine.download(
                remotePath: "/x",
                to: FileManager.default.temporaryDirectory.appendingPathComponent("dm-sched-test"),
                entry: entry,
                background: true
            )
            finished = true
        }

        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(finished, "background download should still be yielding")

        await task.value
        XCTAssertTrue(finished)
        engine.setForegroundCountForTesting(0)
    }

    // MARK: - Foreground/background batch semantics

    private func makeEntry(_ name: String) -> DirEntry {
        DirEntry(
            id: name,
            name: name,
            size: 1,
            modified: Date(timeIntervalSince1970: 0),
            isDir: false,
            mime: "image/jpeg",
            sizeText: "1 B",
            dateText: "—"
        )
    }

    /// Cancelling a background (thumbnail) download mid-navigation must not
    /// write a "Paused" history row — the queue stays user-visible only.
    func testBackgroundCancelDoesNotWriteHistory() async {
        let engine = TransferEngine()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-bg-cancel-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }

        let reqId = 42
        let result = await engine.withPendingDownloadForTesting(reqId: reqId, localURL: url, entry: makeEntry("bg.jpg")) {
            engine.cancelTransfer(reqId)
        }
        XCTAssertFalse(result)
        XCTAssertTrue(engine.transferHistory.isEmpty,
                      "background thumbnail cancel must not pollute transfer history")
    }

    /// The cancel marker survives the retry-decision check so the batch
    /// aggregator can consume it (and must not be double-consumable).
    func testBackgroundCancelMarkerIsConsumable() async {
        let engine = TransferEngine()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-bg-marker-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }

        let reqId = 43
        _ = await engine.withPendingDownloadForTesting(reqId: reqId, localURL: url, entry: makeEntry("bg.jpg")) {
            engine.cancelTransfer(reqId)
        }
        XCTAssertTrue(engine.consumeExplicitDownloadCancellation(for: url))
        XCTAssertFalse(engine.consumeExplicitDownloadCancellation(for: url),
                       "marker must be consumed exactly once")
    }

    /// Restored history must not collide with fresh request ids.
    func testRestoreHistoryBumpsNextRequestID() {
        let engine = TransferEngine()
        let record = TransferRecord(
            id: 7,
            name: "a.jpg",
            bytes: 1,
            direction: .download,
            status: .completed,
            timestamp: Date(timeIntervalSince1970: 1),
            errorMessage: nil,
            entry: nil,
            destinationURL: nil,
            remotePath: nil
        )
        // restoreHistory loads from disk — persist first, then restore.
        let serial = "restore-request-id-test"
        TransferHistoryStore.save(serial: serial, records: [record])
        defer {
            let url = TransferHistoryStore.url(for: serial)
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("corrupt"))
        }
        engine.restoreHistory(serial: serial)
        XCTAssertEqual(engine.transferHistory.count, 1)
        XCTAssertEqual(engine.nextRequestIDForTesting, 8,
                       "fresh transfers must not collide with restored history ids")
    }
}
