import XCTest
@testable import DroidMate
import DroidMateWire

final class ConnectionUXTests: XCTestCase {

    func testAdbOperationRunsOffMainActor() async throws {
        let ranOnMainThread = try await ConnectionManager.runAdbOperation {
            Thread.isMainThread
        }
        XCTAssertFalse(ranOnMainThread)
    }

    func testCancellingAdbOperationTerminatesProcess() async throws {
        let started = Date()
        let task = Task {
            try await ConnectionManager.runAdbOperation {
                try AdbRunner.run("/bin/sleep", args: ["5"], timeout: 10)
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testCancelledAdbOperationCannotReturnSuccessWhenWorkIgnoresCancellation() async throws {
        let task = Task {
            try await ConnectionManager.runAdbOperation {
                Thread.sleep(forTimeInterval: 0.08)
                return "finished"
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation wins even when the synchronous work ignores it.
        }
    }

    @MainActor
    func testDisconnectAllWaitsForCleanupStartedByNormalDisconnect() async throws {
        let gate = CleanupGate()
        let manager = ConnectionManager { _, _, _, _ in
            await gate.run()
        }

        manager.disconnect("192.0.2.10:5555")
        await gate.waitUntilStarted()

        let completion = CompletionFlag()
        let shutdown = Task { @MainActor in
            await manager.disconnectAll()
            await completion.markFinished()
        }
        try await Task.sleep(for: .milliseconds(30))
        let finishedEarly = await completion.isFinished
        XCTAssertFalse(finishedEarly)

        await gate.finish()
        await shutdown.value
        let finishedAfterCleanup = await completion.isFinished
        XCTAssertTrue(finishedAfterCleanup)
    }

    @MainActor
    func testDisconnectAllCancelsAndWaitsForManagedConnectionWorkflow() async {
        let probe = ConnectionWorkflowProbe()
        let manager = ConnectionManager()
        manager.startConnectionWorkflow {
            await probe.runUntilCancelled()
        }
        await probe.waitUntilStarted()

        await manager.disconnectAll()

        let cancellationObserved = await probe.cancellationObserved
        XCTAssertTrue(cancellationObserved)
    }

    @MainActor
    func testDisconnectAllTearsDownProvisionalWirelessWithoutSession() async {
        let cleaned = CleanupRecorder()
        let manager = ConnectionManager { serial, localPort, disconnectWifi, stopServer in
            await cleaned.record(
                serial: serial,
                localPort: localPort,
                disconnectWifi: disconnectWifi,
                stopServer: stopServer
            )
        }

        // Simulates: adb connect succeeded, DeviceSession not yet created, user quits.
        manager.noteProvisionalWireless("192.0.2.20:5555")
        await manager.disconnectAll()

        let records = await cleaned.records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].serial, "192.0.2.20:5555")
        XCTAssertNil(records[0].localPort)
        XCTAssertTrue(records[0].disconnectWifi)
        XCTAssertTrue(records[0].stopServer)
    }

    @MainActor
    func testProvisionalWirelessClearedWhenSessionCreatedPathWouldOwnCleanup() async {
        let cleaned = CleanupRecorder()
        let manager = ConnectionManager { serial, localPort, disconnectWifi, stopServer in
            await cleaned.record(
                serial: serial,
                localPort: localPort,
                disconnectWifi: disconnectWifi,
                stopServer: stopServer
            )
        }

        manager.noteProvisionalWireless("192.0.2.30:5555")
        manager.clearProvisionalWireless("192.0.2.30:5555")
        await manager.disconnectAll()

        let records = await cleaned.records
        XCTAssertTrue(records.isEmpty)
    }

    @MainActor
    func testRelatedSerialsUsesCachedDeviceScan() {
        let manager = ConnectionManager()
        AdbBridge.shared.rememberUsbIp(serial: "USB123", ip: "192.168.1.8")
        defer { AdbBridge.shared.clearDeviceCaches(serial: "USB123") }
        manager.syncAutoConnectSuppression(withPresentSerials: [
            "USB123",
            "192.168.1.8:5555",
        ])

        XCTAssertEqual(
            Set(manager.relatedSerials(for: "USB123")),
            Set(["USB123", "192.168.1.8:5555"])
        )
    }

    // MARK: - Auto-connect preference

    func testPickAutoConnectPrefersLastConnected() {
        let list = ["USBAAA", "192.168.1.2:5555"]
        let pick = ConnectionManager.pickAutoConnectSerial(
            from: list,
            lastConnected: "192.168.1.2:5555",
            shouldConnect: { _ in true }
        )
        XCTAssertEqual(pick, "192.168.1.2:5555")
    }

    func testPickAutoConnectPrefersUSBWhenNoLast() {
        let list = ["192.168.1.2:5555", "USBAAA", "10.0.0.1:5555"]
        let pick = ConnectionManager.pickAutoConnectSerial(
            from: list,
            lastConnected: nil,
            shouldConnect: { _ in true }
        )
        XCTAssertEqual(pick, "USBAAA")
    }

    func testPickAutoConnectSkipsSuppressed() {
        let list = ["USBAAA", "USBBBB"]
        let pick = ConnectionManager.pickAutoConnectSerial(
            from: list,
            lastConnected: "USBAAA",
            shouldConnect: { $0 != "USBAAA" }
        )
        XCTAssertEqual(pick, "USBBBB")
    }

    func testPickAutoConnectNilWhenAllBlocked() {
        let pick = ConnectionManager.pickAutoConnectSerial(
            from: ["USBAAA"],
            lastConnected: "USBAAA",
            shouldConnect: { _ in false }
        )
        XCTAssertNil(pick)
    }

    // MARK: - Device grouping

    func testGroupMergesUSBAndWifiByIP() {
        let devices = [
            AdbBridge.DeviceInfo(serial: "USB123", state: "device"),
            AdbBridge.DeviceInfo(serial: "192.168.1.8:5555", state: "device"),
            AdbBridge.DeviceInfo(serial: "192.168.1.9:5555", state: "device"),
        ]
        let groups = ConnectionDeviceGrouping.groups(
            devices: devices,
            modelBySerial: ["USB123": "Pixel 8"],
            usbIpBySerial: ["USB123": "192.168.1.8"]
        )
        XCTAssertEqual(groups.count, 2)
        let merged = groups.first { $0.hasUSB && $0.hasWireless }
        XCTAssertNotNil(merged)
        XCTAssertEqual(merged?.title, "Pixel 8")
        XCTAssertEqual(Set(merged?.serials ?? []), Set(["USB123", "192.168.1.8:5555"]))
        XCTAssertEqual(merged?.connectSerial, "USB123")
        let alone = groups.first { $0.id == "192.168.1.9:5555" }
        XCTAssertNotNil(alone)
        XCTAssertTrue(alone?.hasWireless == true)
        XCTAssertFalse(alone?.hasUSB == true)
    }

    func testGroupWithoutIPKeepsSeparate() {
        let devices = [
            AdbBridge.DeviceInfo(serial: "USB123", state: "device"),
            AdbBridge.DeviceInfo(serial: "192.168.1.8:5555", state: "device"),
        ]
        let groups = ConnectionDeviceGrouping.groups(
            devices: devices,
            modelBySerial: [:],
            usbIpBySerial: [:]
        )
        XCTAssertEqual(groups.count, 2)
    }

    func testGroupIsReadyWhenOnlyUSBReady() {
        let devices = [
            AdbBridge.DeviceInfo(serial: "USB123", state: "device"),
            AdbBridge.DeviceInfo(serial: "192.168.1.8:5555", state: "offline"),
        ]
        let groups = ConnectionDeviceGrouping.groups(
            devices: devices,
            modelBySerial: ["USB123": "Pixel 8"],
            usbIpBySerial: ["USB123": "192.168.1.8"]
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].isReady)
        XCTAssertEqual(groups[0].connectSerial, "USB123")
    }

    // MARK: - My phones online exclusion

    func testMyPhonesExcludeOnlineRows() {
        let online = ["192.168.1.8:5555"]
        let recent = [AdbBridge.WifiEndpoint(host: "192.168.1.8", port: 5555),
                      AdbBridge.WifiEndpoint(host: "10.0.0.2", port: 5555)]
        let rows = WifiPhoneRowModel.build(
            onlineSerials: online,
            recent: recent,
            mdns: [],
            includeOnlineRows: false
        )
        // Online host filtered out of recent; only 10.0.0.2 remains.
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.endpoint?.host, "10.0.0.2")
        XCTAssertFalse(rows.contains(where: \.isOnline))
    }

    func testMyPhonesIncludeOnlineWhenRequested() {
        let rows = WifiPhoneRowModel.build(
            onlineSerials: ["192.168.1.8:5555"],
            recent: [],
            mdns: [],
            includeOnlineRows: true
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isOnline)
    }
}

private actor CleanupGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiter: CheckedContinuation<Void, Never>?

    func run() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            finishWaiter = continuation
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish() {
        finishWaiter?.resume()
        finishWaiter = nil
    }
}

private actor CompletionFlag {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}

private actor ConnectionWorkflowProbe {
    private var started = false
    private(set) var cancellationObserved = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func runUntilCancelled() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        do {
            try await Task.sleep(for: .seconds(10))
        } catch is CancellationError {
            cancellationObserved = true
        } catch {
            // The probe only expects task cancellation.
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

private actor CleanupRecorder {
    struct Record: Equatable {
        let serial: String
        let localPort: UInt16?
        let disconnectWifi: Bool
        let stopServer: Bool
    }

    private(set) var records: [Record] = []

    func record(
        serial: String,
        localPort: UInt16?,
        disconnectWifi: Bool,
        stopServer: Bool
    ) {
        records.append(
            Record(
                serial: serial,
                localPort: localPort,
                disconnectWifi: disconnectWifi,
                stopServer: stopServer
            )
        )
    }
}
