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

    func testPreviewCacheIdentityIncludesRemotePath() {
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let dcim = PreviewController.cacheKey(
            remotePath: "DCIM/IMG.jpg", size: 4_096, modified: modified
        )
        let pictures = PreviewController.cacheKey(
            remotePath: "Pictures/IMG.jpg", size: 4_096, modified: modified
        )
        XCTAssertNotEqual(dcim, pictures)
    }

    func testSameNamedReplacementUploadAlwaysStartsFresh() throws {
        let destination = "Download/report.pdf"
        let oldPayload = try XCTUnwrap(TransferEngine.freshUploadStartPayload(
            reqId: 1,
            destPath: destination,
            size: 10,
            modified: 100,
            mime: "application/pdf"
        ))
        let replacementPayload = try XCTUnwrap(TransferEngine.freshUploadStartPayload(
            reqId: 2,
            destPath: destination,
            size: 20,
            modified: 200,
            mime: "application/pdf"
        ))

        for payload in [oldPayload, replacementPayload] {
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: payload) as? [String: Any]
            )
            XCTAssertNil(json["offset"], "Mac uploads must not append to an unbound remote partial")
        }
    }

    func testUploadPlanKeepsCapturedDestinationAfterNavigation() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroidMateUploadPlanTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let file = temp.appendingPathComponent("note.txt")
        let folder = temp.appendingPathComponent("Photos", isDirectory: true)
        try Data("new".utf8).write(to: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let client = FileClient()
        client.currentPath = "Download/Inbox"
        let destinationRoot = client.currentPath
        let jobs = client.makeUploadJobs(
            [file, folder],
            renameMap: ["Photos": "Camera"],
            destinationRoot: destinationRoot
        )

        client.currentPath = "DCIM"

        XCTAssertEqual(
            jobs.map(\.destPath).sorted(),
            ["Download/Inbox/Camera", "Download/Inbox/note.txt"]
        )
        XCTAssertEqual(jobs.first { $0.localURL == folder }?.isDirectory, true)
    }

    func testUploadSourceRevisionChangesWhenFileIsReplaced() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroidMateUploadRevision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("same-name.bin")
        try Data("AAAA".utf8).write(to: file)
        let original = try XCTUnwrap(UploadSourceRevision(url: file))

        try FileManager.default.removeItem(at: file)
        try Data("BBBB".utf8).write(to: file)
        let replacement = try XCTUnwrap(UploadSourceRevision(url: file))

        XCTAssertNotEqual(original, replacement)
        XCTAssertEqual(original.size, replacement.size)
    }

    @MainActor
    func testUploadDestinationClaimNormalizesAndExcludesConcurrentWriter() throws {
        let engine = TransferEngine()
        var heldClaim: String?
        defer {
            if let heldClaim { engine.releaseUploadDestination(heldClaim) }
        }

        let first = try XCTUnwrap(
            engine.claimUploadDestination("/sdcard/Download/report.pdf")
        )
        heldClaim = first
        XCTAssertNil(
            engine.claimUploadDestination("/sdcard//Download/report.pdf")
        )

        engine.releaseUploadDestination(first)
        heldClaim = nil
        heldClaim = try XCTUnwrap(
            engine.claimUploadDestination("/sdcard/Download/report.pdf")
        )
    }

    @MainActor
    func testUploadDestinationClaimsArePerEngineNotProcessGlobal() throws {
        let phoneA = TransferEngine()
        let phoneB = TransferEngine()
        let path = "/sdcard/Download/report.pdf"
        let claimA = try XCTUnwrap(phoneA.claimUploadDestination(path))
        defer { phoneA.releaseUploadDestination(claimA) }
        // Same remote path on another device must not be blocked.
        let claimB = try XCTUnwrap(phoneB.claimUploadDestination(path))
        phoneB.releaseUploadDestination(claimB)
    }
}
