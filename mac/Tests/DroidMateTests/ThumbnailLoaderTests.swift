import XCTest
@testable import DroidMate

@MainActor
final class ThumbnailLoaderTests: XCTestCase {

    /// ImageIO must render a ≤512px thumbnail without materializing the
    /// full-size bitmap (decodeImageThumbnail path).
    func testImageThumbnailCapsAt512Pixels() async throws {
        // Build a 1024×1024 PNG on disk.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroidMateThumbTests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test-1024.png")

        let image = NSImage(size: NSSize(width: 1024, height: 1024))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("could not synthesize test PNG")
            return
        }
        try png.write(to: url)

        let box = await ThumbnailLoader.load(at: url, type: .image)
        guard let thumb = box?.image else {
            XCTFail("thumbnail decode returned nil")
            return
        }
        let longSide = max(thumb.size.width, thumb.size.height)
        XCTAssertGreaterThan(longSide, 0)
        XCTAssertLessThanOrEqual(longSide, 512)
    }

    /// Corrupt/non-image files fall back to nil without crashing.
    func testImageThumbnailNilForCorruptFile() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroidMateThumbTests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("corrupt.jpg")
        try? Data("not an image".utf8).write(to: url)

        let box = await ThumbnailLoader.load(at: url, type: .image)
        XCTAssertNil(box)
    }
}
