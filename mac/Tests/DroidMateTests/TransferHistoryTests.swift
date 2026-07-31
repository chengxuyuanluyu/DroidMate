import XCTest
@testable import DroidMate

@MainActor
final class TransferHistoryTests: XCTestCase {

    func testClearCompletedKeepsFailedAndCancelled() {
        let engine = TransferEngine()
        let done = TransferRecord(
            id: 1, name: "a.jpg", bytes: 10, direction: .download,
            status: .completed, timestamp: Date(), errorMessage: nil,
            entry: nil, destinationURL: nil, remotePath: nil
        )
        let failed = TransferRecord(
            id: 2, name: "b.jpg", bytes: 0, direction: .download,
            status: .failed, timestamp: Date(), errorMessage: "x",
            entry: nil, destinationURL: nil, remotePath: nil
        )
        let paused = TransferRecord(
            id: 3, name: "c.jpg", bytes: 5, direction: .upload,
            status: .cancelled, timestamp: Date(), errorMessage: "paused",
            entry: nil, destinationURL: nil, remotePath: nil
        )
        engine.replaceHistoryForTesting([done, failed, paused])
        XCTAssertEqual(engine.transferHistory.count, 3)

        engine.clearCompletedHistory()
        XCTAssertEqual(engine.transferHistory.count, 2)
        XCTAssertTrue(engine.transferHistory.allSatisfy { $0.status != .completed })
        XCTAssertEqual(Set(engine.transferHistory.map(\.id)), Set([2, 3]))
    }
}
