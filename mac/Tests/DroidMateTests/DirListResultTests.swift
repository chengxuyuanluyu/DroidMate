import XCTest
@testable import DroidMate

final class DirListResultTests: XCTestCase {

    func testParseListIncludesExistsAndIsDir() throws {
        let json = """
        {"req_id":7,"exists":true,"is_dir":true,"entries":[
          {"name":"a.txt","size":10,"modified":0,"is_dir":false,"mime":"text/plain"}
        ]}
        """.data(using: .utf8)!
        let result = try XCTUnwrap(DirEntry.parseList(json))
        XCTAssertEqual(result.reqId, 7)
        XCTAssertTrue(result.exists)
        XCTAssertTrue(result.isDir)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].name, "a.txt")
        XCTAssertFalse(result.entries[0].isDir)
    }

    func testParseListMissingPath() throws {
        let json = #"{"req_id":1,"exists":false,"is_dir":false,"entries":[]}"#.data(using: .utf8)!
        let result = try XCTUnwrap(DirEntry.parseList(json))
        XCTAssertFalse(result.exists)
        XCTAssertFalse(result.isDir)
        XCTAssertTrue(result.entries.isEmpty)
    }

    func testParseListPathIsFile() throws {
        let json = #"{"req_id":2,"exists":true,"is_dir":false,"entries":[]}"#.data(using: .utf8)!
        let result = try XCTUnwrap(DirEntry.parseList(json))
        XCTAssertTrue(result.exists)
        XCTAssertFalse(result.isDir)
    }

    /// Older servers omit exists/is_dir — treat as present directory.
    func testParseListLegacyOmitsPathFlags() throws {
        let json = #"{"req_id":3,"entries":[]}"#.data(using: .utf8)!
        let result = try XCTUnwrap(DirEntry.parseList(json))
        XCTAssertTrue(result.exists)
        XCTAssertTrue(result.isDir)
        XCTAssertTrue(result.entries.isEmpty)
    }

    func testMissingStatic() {
        XCTAssertFalse(DirListResult.missing.exists)
        XCTAssertFalse(DirListResult.missing.isDir)
        XCTAssertTrue(DirListResult.missing.entries.isEmpty)
    }
}
