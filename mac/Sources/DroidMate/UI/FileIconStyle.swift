import SwiftUI
import AVFoundation
import CoreMedia
import ImageIO
import PDFKit

/// SF Symbol + tint colour for a `DirEntry`. Shared by the list
/// row, grid tile, and inspector so the three surfaces never drift.
enum FileIconStyle {
    static func name(for entry: DirEntry) -> String {
        let m = entry.mime
        let n = entry.name.lowercased()
        if m.hasPrefix("image/") { return "photo" }
        if m.hasPrefix("video/") { return "film" }
        if m.hasPrefix("audio/") { return "music.note" }
        if m == "application/pdf" { return "doc.text.fill" }
        if n.hasSuffix(".apk") { return "app.fill" }
        if n.hasSuffix(".zip") || m == "application/zip"
            || n.hasSuffix(".gz") || n.hasSuffix(".rar") || n.hasSuffix(".7z") {
            return "archivebox"
        }
        if m.hasPrefix("text/") || n.hasSuffix(".txt") || n.hasSuffix(".md") {
            return "doc.plaintext"
        }
        return "doc"
    }

    static func color(for entry: DirEntry) -> Color {
        let m = entry.mime
        let n = entry.name.lowercased()
        // Slightly desaturated tints — less “rainbow junk drawer”, more Finder-adjacent.
        if m.hasPrefix("image/") { return Color(.sRGB, red: 0.62, green: 0.40, blue: 0.88, opacity: 1) }
        if m.hasPrefix("video/") { return Color(.sRGB, red: 0.40, green: 0.42, blue: 0.86, opacity: 1) }
        if m.hasPrefix("audio/") { return Color(.sRGB, red: 0.86, green: 0.38, blue: 0.55, opacity: 1) }
        if m == "application/pdf" { return Color(.sRGB, red: 0.86, green: 0.32, blue: 0.30, opacity: 1) }
        if n.hasSuffix(".apk") { return Color(.sRGB, red: 0.28, green: 0.68, blue: 0.42, opacity: 1) }
        if n.hasSuffix(".zip") || m == "application/zip"
            || n.hasSuffix(".gz") || n.hasSuffix(".rar") || n.hasSuffix(".7z") {
            return Color(.sRGB, red: 0.90, green: 0.55, blue: 0.22, opacity: 1)
        }
        if m.hasPrefix("text/") || n.hasSuffix(".txt") || n.hasSuffix(".md") {
            return Color(.sRGB, red: 0.30, green: 0.52, blue: 0.88, opacity: 1)
        }
        return .secondary
    }
}

/// Decodes image files and extracts video first-frames off the main thread.
/// NSImage / CGImage aren't Sendable, so results are boxed via @unchecked.
enum ThumbnailLoader {
    struct Box: @unchecked Sendable {
        let image: NSImage
    }

    enum MediaType { case image, video, pdf }

    static func load(at url: URL, type: MediaType) async -> Box? {
        switch type {
        case .image:
            // Decode off the main thread and render only a ≤512px thumbnail —
            // ImageIO never materializes the full-size bitmap.
            return await Task.detached(priority: .utility) {
                ThumbnailLoader.decodeImageThumbnail(at: url)
            }.value
        case .video:
            return await generateVideoThumbnail(at: url)
        case .pdf:
            return generatePdfThumbnail(at: url)
        }
    }

    /// Backs `load(.image)`: reads a ≤512px thumbnail directly from the file
    /// via ImageIO. HEIC/JPEG embedded thumbnails are returned as-is, which is
    /// dramatically faster than decoding the full-size frame.
    private static func decodeImageThumbnail(at url: URL) -> Box? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return Box(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
    }

    private static func generatePdfThumbnail(at url: URL) -> Box? {
        guard let doc = PDFDocument(url: url),
              let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(200.0 / bounds.width, 200.0 / bounds.height)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return Box(image: page.thumbnail(of: size, for: .mediaBox))
    }

    private static func generateVideoThumbnail(at url: URL) async -> Box? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        // Mobile HEVC clips often open on a black first frame — prefer the 1s
        // frame and fall back to the first frame if seeking fails. Loose
        // tolerance avoids an exact-keyframe seek.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        for time in [CMTime(seconds: 1, preferredTimescale: 600), .zero] {
            do {
                let cgImage = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CGImage, Error>) in
                    generator.generateCGImageAsynchronously(for: time) { image, _, error in
                        if let image { cont.resume(returning: image) }
                        else { cont.resume(throwing: error ?? NSError(domain: "AVFoundation", code: -1)) }
                    }
                }
                return Box(image: NSImage(cgImage: cgImage,
                                         size: NSSize(width: cgImage.width, height: cgImage.height)))
            } catch {
                continue
            }
        }
        return nil
    }
}
