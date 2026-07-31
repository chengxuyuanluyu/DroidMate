import XCTest
@testable import DroidMateMCP

final class PathSafetyTests: XCTestCase {

    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(PathSafety.shellQuote("a"), "'a'")
        XCTAssertEqual(PathSafety.shellQuote("a'b"), "'a'\\''b'")
        XCTAssertEqual(PathSafety.shellQuote("/sdcard/My Files"), "'/sdcard/My Files'")
    }

    func testSafePackage() {
        XCTAssertTrue(PathSafety.isSafePackage("com.android.settings"))
        XCTAssertTrue(PathSafety.isSafePackage("a_b.1"))
        XCTAssertFalse(PathSafety.isSafePackage(""))
        XCTAssertFalse(PathSafety.isSafePackage("com;rm -rf /"))
        XCTAssertFalse(PathSafety.isSafePackage("has space"))
    }

    func testValidateDevicePathAbsolute() {
        XCTAssertNil(PathSafety.validateDevicePath("/sdcard/Download", allowRoots: true))
        XCTAssertNotNil(PathSafety.validateDevicePath("relative", allowRoots: true))
        XCTAssertNotNil(PathSafety.validateDevicePath("", allowRoots: true))
    }

    func testValidateDevicePathProtectsRoots() {
        XCTAssertNotNil(PathSafety.validateDevicePath("/", allowRoots: false))
        XCTAssertNotNil(PathSafety.validateDevicePath("/sdcard", allowRoots: false))
        XCTAssertNotNil(PathSafety.validateDevicePath("/storage/emulated/0", allowRoots: false))
        XCTAssertNil(PathSafety.validateDevicePath("/sdcard/Download/x", allowRoots: false))
        // Trailing slash collapses before root check.
        XCTAssertNotNil(PathSafety.validateDevicePath("/sdcard/", allowRoots: false))
    }

    func testValidateAllowsRootsWhenRequested() {
        XCTAssertNil(PathSafety.validateDevicePath("/", allowRoots: true))
        XCTAssertNil(PathSafety.validateDevicePath("/sdcard", allowRoots: true))
    }
}
