import AppKit
import Quartz

/// QuickLook bridge. Downloads a remote file into the preview cache (skipping
/// the download when a same-size copy is already cached), then opens the
/// system QLPreviewPanel. Works for images, videos, PDFs, text — anything
/// QuickLook supports. Single-item panels only; folder-wide arrow navigation
/// would require downloading every file up front.
///
/// Cache key is a hash of the remote path + metadata, not just the filename —
/// otherwise /DCIM/IMG.jpg and /Pictures/IMG.jpg would collide.
final class PreviewController: NSObject, ObservableObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated(unsafe) static let shared = PreviewController()
    private var items: [URL] = []

    /// Progress overlay shown while downloading a file for preview.
    @Published var isPreparing = false
    @Published var preparingName: String?

    private let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DroidMatePreview", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Preview cache ceiling (2 GB). QuickLook needs whole files, and videos
    /// can be hundreds of MB, so this bounds the cache between trims.
    private let maxCacheBytes: Int64 = 2_000_000_000

    @MainActor func preview(entry: DirEntry, using client: FileClient) async {
        guard !entry.isDir else { return }

        let remotePath = client.child(of: client.currentPath, name: entry.name)
        let key = Self.cacheKey(
            remotePath: remotePath,
            size: entry.size,
            modified: entry.modified
        )
        let dest = cacheDir.appendingPathComponent(key + "_" + entry.name)

        let cachedSize = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if cachedSize != Int(entry.size) {
            // Enforce the cap only before an actual download, and never evict
            // the file we are about to write.
            enforceCacheCap(excluding: dest)
            // Show progress overlay — QuickLook needs the full file, so the
            // user sees something instead of a frozen click.
            preparingName = entry.name
            isPreparing = true
            defer { isPreparing = false; preparingName = nil }
            let ok = await client.downloadAndWait(remotePath: remotePath, entry: entry, to: dest)
            guard ok else {
                // User-paused preview downloads are not failures.
                if !client.consumeExplicitDownloadCancellation(for: dest) {
                    client.error = String(localized: "Couldn't download \(entry.name) for preview")
                }
                return
            }
        }

        items = [dest]
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    /// Evicts cache entries older than 7 days. Called on app launch.
    @MainActor func trimCache() {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in entries {
            let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let mod, mod < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Called before a download: if the cache exceeds `maxCacheBytes`, evicts
    /// least-recently-modified files until it fits again, never removing `keep`.
    /// Keeps the directory bounded between launch-time trims.
    @MainActor private func enforceCacheCap(excluding keep: URL? = nil) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }

        var total: Int64 = 0
        var dated: [(url: URL, date: Date, size: Int64)] = []
        for url in entries {
            if url.path == keep?.path { continue }
            let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = Int64(attrs?.fileSize ?? 0)
            total += size
            dated.append((url, attrs?.contentModificationDate ?? .distantPast, size))
        }
        guard total > maxCacheBytes else { return }

        dated.sort { $0.date < $1.date }
        for item in dated {
            try? FileManager.default.removeItem(at: item.url)
            total -= item.size
            if total <= maxCacheBytes { break }
        }
    }

    static func cacheKey(remotePath: String, size: Int64, modified: Date) -> String {
        // Not cryptographic; metadata only needs a stable local cache identity.
        let modifiedMs = Int64(modified.timeIntervalSince1970 * 1_000)
        let raw = "\(remotePath)\0\(size)\0\(modifiedMs)"
        return raw.djb2
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        items[index] as NSURL
    }
}

private extension String {
    /// Daniel J. Bernstein's hash — fast, good distribution for cache keys.
    var djb2: String {
        var hash: UInt64 = 5381
        for byte in utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}
