import XCTest
@testable import DroidMate

final class NameConflictTests: XCTestCase {

    func testUniqueNameNoConflict() {
        XCTAssertEqual(NameConflict.uniqueName("a.txt", among: []), "a.txt")
        XCTAssertEqual(NameConflict.uniqueName("a.txt", among: ["b.txt"]), "a.txt")
    }

    func testUniqueNameWithExtension() {
        let existing: Set = ["photo.jpg"]
        XCTAssertEqual(NameConflict.uniqueName("photo.jpg", among: existing), "photo (1).jpg")
        let more: Set = ["photo.jpg", "photo (1).jpg"]
        XCTAssertEqual(NameConflict.uniqueName("photo.jpg", among: more), "photo (2).jpg")
    }

    func testUniqueNameNoExtension() {
        let existing: Set = ["README"]
        XCTAssertEqual(NameConflict.uniqueName("README", among: existing), "README (1)")
    }

    func testCopyNameFinderStyle() {
        XCTAssertEqual(NameConflict.copyName("photo.jpg", among: []), "photo copy.jpg")
        XCTAssertEqual(
            NameConflict.copyName("photo.jpg", among: ["photo.jpg", "photo copy.jpg"]),
            "photo copy 2.jpg"
        )
        XCTAssertEqual(NameConflict.copyName("README", among: ["README"]), "README copy")
        XCTAssertEqual(
            NameConflict.copyName("README", among: ["README", "README copy"]),
            "README copy 2"
        )
    }

    func testAbsoluteDevicePath() async {
        let client = await MainActor.run { FileClient() }
        await MainActor.run {
            XCTAssertEqual(client.absoluteDevicePath(relative: "/"), "/sdcard")
            XCTAssertEqual(client.absoluteDevicePath(relative: "Download"), "/sdcard/Download")
            XCTAssertEqual(
                client.absoluteDevicePath(relative: "Download/Camera/x.jpg"),
                "/sdcard/Download/Camera/x.jpg"
            )
        }
    }
}
