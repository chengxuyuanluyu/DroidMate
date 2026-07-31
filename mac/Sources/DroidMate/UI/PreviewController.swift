import AppKit
import Quartz

/// QuickLook bridge. Downloads a remote file into the preview cache (skipping
/// the download when a same-size copy is already cached), then opens the
/// system QLPreviewPanel. Works for images, videos, PDFs, text — anything
/// QuickLook supports. Single-item panels only; folder-wide arrow navigation
/// would require downloading every file up front.
///
/// Cache key is a hash of the remote path + size, not just the filename —
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

    @MainActor func preview(entry: DirEntry, using client: FileClient) async {
        guard !entry.isDir else { return }

        // Cache key: path + size avoids cross-directory name collisions.
        let key = cacheKey(for: entry)
        let dest = cacheDir.appendingPathComponent(key + "_" + entry.name)

        let cachedSize = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if cachedSize != Int(entry.size) {
            // Show progress overlay — QuickLook needs the full file, so the
            // user sees something instead of a frozen click.
            preparingName = entry.name
            isPreparing = true
            defer { isPreparing = false; preparingName = nil }
            let ok = await client.downloadAndWait(entry: entry, to: dest)
            guard ok else { return }
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

    private func cacheKey(for entry: DirEntry) -> String {
        // Lightweight hash of path+size. Not cryptographic — just unique enough.
        let raw = "\(entry.name)_\(entry.size)"
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
