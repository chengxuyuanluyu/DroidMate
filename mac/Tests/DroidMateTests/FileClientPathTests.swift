import XCTest
@testable import DroidMate

@MainActor
final class FileClientPathTests: XCTestCase {

    func testNormalizeAndParentForDirectoryProbe() {
        let client = FileClient()
        XCTAssertEqual(client.components(of: "Download/Camera").last, "Camera")
        XCTAssertEqual(client.child(of: "Download", name: "Camera"), "Download/Camera")
    }

    /// Without transport, listDir returns `.missing` — non-root paths are not present.
    func testRemoteDirectoryExistsFalseWithoutTransport() async {
        let client = FileClient()
        // Root is always considered present (storage root).
        let rootOk = await client.remoteDirectoryExists("/")
        XCTAssertTrue(rootOk)
        let missing = await client.remoteDirectoryExists("NoSuchFolder_xyz_droidmate")
        XCTAssertFalse(missing)
    }

    /// list without transport must not set a "folder not found" error (reqId 0).
    func testListWithoutTransportDoesNotScreamNotFound() async {
        let client = FileClient()
        let ok = await client.list(path: "Download")
        XCTAssertFalse(ok)
        XCTAssertNil(client.error)
    }

    func testAbsoluteDevicePathRootAndNested() {
        let client = FileClient()
        XCTAssertEqual(client.absoluteDevicePath(relative: "/"), "/sdcard")
        XCTAssertEqual(
            client.absoluteDevicePath(relative: client.child(of: "Download", name: "a.txt")),
            "/sdcard/Download/a.txt"
        )
    }
}

