import XCTest
@testable import DroidMate

@MainActor
final class DeviceSessionRecoveryTests: XCTestCase {

    func testUnavailableManualRecoveryReturnsToActionableState() {
        let session = DeviceSession(deviceSerial: "TEST", port: 28_050)
        session.markRecovering(detail: "trying")
        session.markRecoveryUnavailable(detail: "missing")

        XCTAssertEqual(session.recoveryPhase, .gaveUp("missing"))
    }

    func testLateRecoveryStatusCannotOverwriteReadyState() {
        let session = DeviceSession(deviceSerial: "TEST", port: 28_050)

        session.handleTransportState(.ready)
        session.markRecovering(detail: "late recovery")
        session.markRecoveryUnavailable(detail: "late failure")

        XCTAssertEqual(session.recoveryPhase, .idle)
    }

    func testCancelledSharedRecoveryCanScheduleAnotherAttempt() async {
        let session = DeviceSession(
            deviceSerial: "TEST",
            port: 28_050,
            recoveryDelay: .milliseconds(20)
        )
        let retried = expectation(description: "recovery retried")
        var attempts = 0
        session.onNeedsRecovery = {
            attempts += 1
            if attempts == 1 { throw CancellationError() }
            retried.fulfill()
        }

        session.handleTransportState(.failed("offline"))

        await fulfillment(of: [retried], timeout: 1)
        XCTAssertEqual(attempts, 2)
        session.stop()
    }

    func testRepeatedFailureKeepsPendingRecoveryAndReadyCancelsNextAttempt() async throws {
        let session = DeviceSession(
            deviceSerial: "TEST",
            port: 28_050,
            recoveryDelay: .milliseconds(30)
        )
        let firstRecovery = expectation(description: "first recovery")
        var recoveryCount = 0
        session.onNeedsRecovery = {
            recoveryCount += 1
            firstRecovery.fulfill()
        }

        session.handleTransportState(.failed("first"))
        session.handleTransportState(.failed("second"))
        session.handleTransportState(.failed("third"))

        guard case .recovering(let attempt, _) = session.recoveryPhase else {
            return XCTFail("expected one pending recovery")
        }
        XCTAssertEqual(attempt, 1)

        await fulfillment(of: [firstRecovery], timeout: 1)
        XCTAssertEqual(recoveryCount, 1)

        session.handleTransportState(.failed("again"))
        guard case .recovering(let nextAttempt, _) = session.recoveryPhase else {
            return XCTFail("expected the next recovery attempt")
        }
        XCTAssertEqual(nextAttempt, 2)

        session.handleTransportState(.ready)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertEqual(session.recoveryPhase, .idle)

        session.handleTransportState(.failed("before stop"))
        guard case .recovering(let resetAttempt, _) = session.recoveryPhase else {
            return XCTFail("expected recovery after returning to ready")
        }
        XCTAssertEqual(resetAttempt, 1)
        session.stop()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertEqual(session.recoveryPhase, .idle)
    }
}
