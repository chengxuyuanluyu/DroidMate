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
}
