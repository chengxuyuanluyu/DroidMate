import XCTest
@testable import DroidMate

final class TypeaheadJumpTests: XCTestCase {
    private func entries(_ names: [String]) -> [DirEntry] {
        names.map { name in
            DirEntry(
                id: name, name: name, size: 0, modified: .distantPast,
                isDir: true, mime: "inode/directory", sizeText: "—", dateText: ""
            )
        }
    }

    func testPrefixMatch() {
        var buf = ""
        let list = entries(["Alarms", "Android", "DCIM", "Download"])
        let id = TypeaheadJump.apply(character: "D", buffer: &buf, entries: list, currentSelection: [], anchorID: nil)
        XCTAssertEqual(id, "DCIM")
        XCTAssertEqual(buf, "d")
    }

    func testCycleSameLetter() {
        var buf = "d"
        let list = entries(["Alarms", "DCIM", "Download", "Documents"])
        let id1 = TypeaheadJump.apply(character: "d", buffer: &buf, entries: list, currentSelection: ["DCIM"], anchorID: "DCIM")
        XCTAssertEqual(id1, "Download")
        let id2 = TypeaheadJump.apply(character: "d", buffer: &buf, entries: list, currentSelection: ["Download"], anchorID: "Download")
        XCTAssertEqual(id2, "Documents")
    }

    func testMultiCharPrefix() {
        var buf = ""
        let list = entries(["Camera", "DCIM", "Download"])
        _ = TypeaheadJump.apply(character: "D", buffer: &buf, entries: list, currentSelection: [], anchorID: nil)
        let id = TypeaheadJump.apply(character: "o", buffer: &buf, entries: list, currentSelection: ["DCIM"], anchorID: "DCIM")
        XCTAssertEqual(buf, "do")
        XCTAssertEqual(id, "Download")
    }

    func testFailedPrefixRestartsWithoutCycle() {
        var buf = "dx"
        let list = entries(["DCIM", "Download", "Documents"])
        // "dx" fails → restart on "d"; first match at/after anchor stays on Download (not cycle to Documents).
        let id = TypeaheadJump.apply(character: "d", buffer: &buf, entries: list, currentSelection: ["Download"], anchorID: "Download")
        XCTAssertEqual(buf, "d")
        XCTAssertEqual(id, "Download")
    }
}
