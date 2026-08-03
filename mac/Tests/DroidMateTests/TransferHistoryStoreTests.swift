import XCTest
@testable import DroidMate

@MainActor
final class TransferHistoryStoreTests: XCTestCase {

    private let serial = "TestSerial_1234"

    override func tearDown() {
        // Keep the test machine clean: remove what this suite wrote, including
        // any `.corrupt` backup moved aside by the corrupt-file path.
        let url = TransferHistoryStore.url(for: serial)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("corrupt"))
        super.tearDown()
    }

    private func makeRecord(id: Int) -> TransferRecord {
        TransferRecord(
            id: id,
            name: "file-\(id).jpg",
            bytes: 4_096,
            direction: .download,
            status: .completed,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(id)),
            errorMessage: nil,
            entry: DirEntry(
                id: "file-\(id).jpg",
                name: "file-\(id).jpg",
                size: 4_096,
                modified: Date(timeIntervalSince1970: 1_700_000_000),
                isDir: false,
                mime: "image/jpeg",
                sizeText: "4 KB",
                dateText: "Jul 1, 2025"
            ),
            destinationURL: URL(fileURLWithPath: "/tmp/file-\(id).jpg"),
            remotePath: "DCIM/file-\(id).jpg"
        )
    }

    func testRoundTripPreservesRecords() {
        let records = [makeRecord(id: 1), makeRecord(id: 2), makeRecord(id: 3)]
        TransferHistoryStore.save(serial: serial, records: records)

        let loaded = TransferHistoryStore.load(serial: serial)
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded, records)
        XCTAssertEqual(loaded[0].entry?.mime, "image/jpeg")
        XCTAssertEqual(loaded[1].direction, .download)
    }

    func testSerialsAreIsolated() {
        TransferHistoryStore.save(serial: serial, records: [makeRecord(id: 7)])
        let other = TransferHistoryStore.load(serial: "Another_Serial")
        XCTAssertTrue(other.isEmpty)
    }

    func testCorruptFileLoadsEmptyWithoutCrashing() {
        let url = TransferHistoryStore.url(for: serial)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data("not json".utf8).write(to: url)

        XCTAssertTrue(TransferHistoryStore.load(serial: serial).isEmpty)
    }

    func testMissingFileLoadsEmpty() {
        XCTAssertTrue(TransferHistoryStore.load(serial: "DoesNotExist_9876").isEmpty)
    }
}
