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
        XCTAssertEqual(
            try PathSafety.validateDevicePath("/sdcard//Download/./photo.jpg", allowRoots: true),
            "/sdcard/Download/photo.jpg"
        )
        XCTAssertThrowsError(try PathSafety.validateDevicePath("relative", allowRoots: true))
        XCTAssertThrowsError(try PathSafety.validateDevicePath("", allowRoots: true))
    }

    func testValidateDevicePathProtectsRoots() {
        XCTAssertThrowsError(try PathSafety.validateDevicePath("/", allowRoots: false))
        XCTAssertThrowsError(try PathSafety.validateDevicePath("/sdcard", allowRoots: false))
        XCTAssertThrowsError(try PathSafety.validateDevicePath("/storage/emulated/0", allowRoots: false))
        XCTAssertEqual(
            try PathSafety.validateDevicePath("/sdcard/Download/x", allowRoots: false),
            "/sdcard/Download/x"
        )

        XCTAssertThrowsError(try PathSafety.validateDevicePath("/sdcard//", allowRoots: false))
        XCTAssertThrowsError(try PathSafety.validateDevicePath("/sdcard/../sdcard", allowRoots: false))
        XCTAssertThrowsError(try PathSafety.validateDevicePath("/sdcard/Download/../", allowRoots: false))
        XCTAssertThrowsError(
            try PathSafety.validateDevicePath("/mnt/runtime/default/emulated/0", allowRoots: false)
        )
        XCTAssertThrowsError(try PathSafety.validateDevicePath("/system/etc/hosts", allowRoots: false))
        XCTAssertEqual(
            try PathSafety.validateDevicePath("/data/local/tmp/droidmate", allowRoots: false),
            "/data/local/tmp/droidmate"
        )
    }

    func testValidateAllowsRootsWhenRequested() {
        XCTAssertEqual(try PathSafety.validateDevicePath("/", allowRoots: true), "/")
        XCTAssertEqual(try PathSafety.validateDevicePath("/sdcard/../sdcard//", allowRoots: true), "/sdcard")
    }

    func testValidateRejectsRootEscape() {
        XCTAssertThrowsError(try PathSafety.validateDevicePath("/../sdcard", allowRoots: true))
        XCTAssertThrowsError(try PathSafety.validateDevicePath("/sdcard/../../data", allowRoots: true))
        XCTAssertThrowsError(try PathSafety.validateDevicePath("/sdcard/a\nb", allowRoots: true))
    }

    func testResolvedDestructivePathCannotEscapeThroughSymlink() {
        XCTAssertThrowsError(
            try PathSafety.validateDestructiveResolution(
                requested: "/data/local/tmp/link/system",
                resolved: "/system"
            )
        )
        XCTAssertEqual(
            try PathSafety.validateDestructiveResolution(
                requested: "/sdcard/Download/photo.jpg",
                resolved: "/storage/emulated/0/Download/photo.jpg"
            ),
            "/sdcard/Download/photo.jpg"
        )
    }
}
