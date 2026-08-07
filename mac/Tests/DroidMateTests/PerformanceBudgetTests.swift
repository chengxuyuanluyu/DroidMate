import XCTest
@testable import DroidMate

/// docs/3.0 performance budgets — structural invariants (P4) and policy constants.
@MainActor
final class PerformanceBudgetTests: XCTestCase {

    // MARK: - P4 publish policy

    func testProgressPublishPolicyConstantsMatchSpec() {
        XCTAssertEqual(TransferProgressPublishPolicy.maxPublishHz, 15)
        XCTAssertEqual(TransferProgressPublishPolicy.minProgressDelta, 0.005, accuracy: 1e-9)
    }

    func testForceAlwaysPublishes() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(
            TransferProgressPublishPolicy.shouldPublish(
                progress: 0.1,
                lastPublishedProgress: 0.1,
                lastPublishTime: t0,
                now: t0,
                force: true
            )
        )
    }

    func testSmallDeltaWithinHzWindowDoesNotPublish() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let soon = t0.addingTimeInterval(1.0 / 30) // half of 15 Hz window
        XCTAssertFalse(
            TransferProgressPublishPolicy.shouldPublish(
                progress: 0.101,
                lastPublishedProgress: 0.100,
                lastPublishTime: t0,
                now: soon,
                force: false
            ),
            "sub-delta progress inside the Hz window must not thrash UI"
        )
    }

    func testDeltaAtLeastHalfPercentPublishesImmediately() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let soon = t0.addingTimeInterval(0.001)
        XCTAssertTrue(
            TransferProgressPublishPolicy.shouldPublish(
                progress: 0.20,
                lastPublishedProgress: 0.10,
                lastPublishTime: t0,
                now: soon,
                force: false
            )
        )
    }

    func testStaleWindowPublishesEvenWithTinyDelta() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let later = t0.addingTimeInterval(1.0 / 15 + 0.001)
        XCTAssertTrue(
            TransferProgressPublishPolicy.shouldPublish(
                progress: 0.1001,
                lastPublishedProgress: 0.1000,
                lastPublishTime: t0,
                now: later,
                force: false
            )
        )
    }

    // MARK: - Background exclusion from queue models

    private func makeEntry(_ name: String) -> DirEntry {
        DirEntry(
            id: name,
            name: name,
            size: 100,
            modified: Date(timeIntervalSince1970: 0),
            isDir: false,
            mime: "image/jpeg",
            sizeText: "100 B",
            dateText: "—"
        )
    }

    func testBackgroundPendingDownloadExcludedFromTransfersArray() async {
        let engine = TransferEngine()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-p4-bg-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        _ = await engine.withPendingDownloadForTesting(
            reqId: 9001,
            localURL: url,
            entry: makeEntry("thumb.jpg"),
            background: true
        ) {
            engine.recomputeProgressForTesting(force: true)
            XCTAssertTrue(
                engine.transfers.isEmpty,
                "background downloads must not appear in the user transfer queue (P4)"
            )
            engine.cancelTransfer(9001) // end seam without waiting for timeout
        }
    }

    func testForegroundPendingDownloadAppearsInTransfersArray() async {
        let engine = TransferEngine()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-p4-fg-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        _ = await engine.withPendingDownloadForTesting(
            reqId: 9002,
            localURL: url,
            entry: makeEntry("user.bin"),
            background: false
        ) {
            engine.recomputeProgressForTesting(force: true)
            XCTAssertEqual(engine.transfers.count, 1)
            XCTAssertEqual(engine.transfers.first?.name, "user.bin")
            engine.cancelTransfer(9002)
        }
    }

    // MARK: - Large-folder policy constant (P3 related)

    func testLargeFolderThresholdDocumented() {
        XCTAssertEqual(FileClient.largeFolderThreshold, 1_500)
    }

    /// Grid tiles skip remote thumbs at/above this threshold (P3 / Wave 3).
    func testLargeFolderThresholdIsConservativeForGridThumbs() {
        XCTAssertLessThanOrEqual(FileClient.largeFolderThreshold, 2_000)
        XCTAssertGreaterThan(FileClient.largeFolderThreshold, 500)
    }
}
