import XCTest
@testable import DroidMate

@MainActor
final class AppTerminationCoordinatorTests: XCTestCase {
    func testRepeatedQuitWaitsForPreparationBeforeDisconnectAndReply() async {
        let coordinator = AppTerminationCoordinator()
        let finalizeStarted = AsyncTestGate()
        let finalizeGate = AsyncTestGate()
        var events: [String] = []

        let started = coordinator.begin(
            prepare: {
                events.append("finalize-start")
                await finalizeStarted.open()
                await finalizeGate.wait()
                events.append("finalize-finished")
            },
            disconnect: {
                events.append("disconnect")
            },
            reply: {
                events.append("reply")
            }
        )
        let repeated = coordinator.begin(
            prepare: { events.append("duplicate-finalize") },
            disconnect: { events.append("duplicate-disconnect") },
            reply: { events.append("duplicate-reply") }
        )

        XCTAssertTrue(started)
        XCTAssertFalse(repeated)
        await finalizeStarted.wait()
        XCTAssertEqual(events, ["finalize-start"])

        await finalizeGate.open()
        await coordinator.waitForCompletion()

        XCTAssertEqual(events, [
            "finalize-start",
            "finalize-finished",
            "disconnect",
            "reply",
        ])
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
