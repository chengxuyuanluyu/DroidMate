import Foundation
import AppKit

/// Disk-backed thumbnail cache for image and video files.
///
/// Responsibilities:
///   - Cache path generation (keyed by remote path + name + size + modified)
///   - Cache hit detection (rendered thumbnail exists)
///   - Thumbnail generation orchestration (download → decode → cache)
///   - Originals kept 24h as a re-render source; thumbnails live 7 days
///   - LRU eviction (200 MB cap)
///
/// Called by FileGridTile and FileInspectorView — they just call
/// `getThumbnail(for:client:)` and get back an NSImage (or nil).
/// No cache logic lives in the views.
@MainActor
final class ThumbnailCache {

    static let shared = ThumbnailCache()

    private let cacheDir: URL
    /// Full-size image downloads are rendered to a small JPEG and then kept
    /// only 24h, so this cap mostly bounds download cost. 25 MB covers
    /// virtually all phone camera JPEGs; larger files (RAW, big HEIC) fall
    /// back to icon-only.
    private let maxImageBytes: Int64 = 25_000_000
    private let maxVideoBytes: Int64 = 10_000_000
    private let maxPdfBytes: Int64 = 5_000_000
    private var maxTotalSize: Int64 {
        let mb = UserDefaults.standard.object(forKey: "cache.limit_mb") as? Int ?? 200
        return Int64(mb) * 1_000_000
    }
    /// Running estimate of retained bytes, so the mid-session cap trips a
    /// trim without a full directory scan on every download.
    private var cachedBytes: Int64 = 0

    private init() {
        cacheDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DroidMateThumb", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true)
        cachedBytes = cacheSize()
    }

    // MARK: - Public API

    func canThumbnail(_ entry: DirEntry) -> Bool {
        if entry.mime.hasPrefix("image/") && entry.size <= maxImageBytes { return true }
        if entry.mime.hasPrefix("video/") && entry.size <= maxVideoBytes { return true }
        if entry.mime == "application/pdf" && entry.size <= maxPdfBytes { return true }
        return false
    }

    func isVideo(_ entry: DirEntry) -> Bool {
        entry.mime.hasPrefix("video/")
    }

    private func mediaType(for entry: DirEntry) -> ThumbnailLoader.MediaType {
        if entry.mime.hasPrefix("image/") { return .image }
        if entry.mime.hasPrefix("video/") { return .video }
        return .pdf
    }

    // MARK: - Scheduling (dedup + concurrency cap + foreground yield)

    /// In-flight fetches keyed by remote-path cache key — concurrent requests
    /// for the same remote file share one download (dedup). Keyed by path, not
    /// entry.id (name-only), so same-named files in different directories
    /// never share a fetch.
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    /// Caps simultaneous thumbnail downloads so they can't flood the transport.
    /// Dropped to 1 while many waiters queue up (huge media folders).
    private var maxConcurrent: Int { waiters.count > 8 ? 1 : 2 }
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Loads (or downloads + generates) a thumbnail for `entry`.
    ///
    /// - Concurrent calls for the same entry share one fetch (dedup).
    /// - At most `maxConcurrent` thumbnails download at once.
    /// - Thumbnail downloads yield while a user-initiated transfer is active,
    ///   so browsing thumbnails never starves a manual download/upload.
    func getThumbnail(
        for entry: DirEntry,
        client: FileClient
    ) async -> NSImage? {
        guard !entry.isDir, canThumbnail(entry) else { return nil }

        // Huge unfiltered folders: skip remote thumbnail fetch (icons only).
        // Keeps list/grid scrolling smooth; search/filter re-enables thumbs.
        if client.entries.count >= FileClient.largeFolderThreshold,
           client.searchQuery.isEmpty,
           client.filterType == .all {
            return nil
        }

        // Capture the remote path now so navigation during a queued fetch
        // can't redirect the download to the wrong file.
        let remotePath = client.child(of: client.currentPath, name: entry.name)
        let key = cacheKey(for: remotePath)

        // Dedup: share an in-flight fetch for the same remote file.
        if let task = inflight[key] { return await task.value }

        let task = Task { @MainActor in
            await self.fetchThumbnail(for: entry, remotePath: remotePath, cacheKey: key, client: client)
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        return result
    }

    private func fetchThumbnail(
        for entry: DirEntry,
        remotePath: String,
        cacheKey: String,
        client: FileClient
    ) async -> NSImage? {
        let type = mediaType(for: entry)
        let mediaPath = mediaPath(cacheKey: cacheKey, name: entry.name)
        let thumb = thumbPath(cacheKey: cacheKey, name: entry.name, size: entry.size, modified: entry.modified)

        // Fast path: cached rendered thumbnail. All media types persist a small
        // JPEG; the full-size original is kept for the 24h TTL below.
        if FileManager.default.fileExists(atPath: thumb.path) {
            if let img = await ThumbnailLoader.load(at: thumb, type: .image)?.image {
                return img
            }
            // Corrupt/truncated thumbnail (crash mid-write, ENOSPC): drop it
            // and fall through to re-render instead of failing forever.
            try? FileManager.default.removeItem(at: thumb)
        }
        // Original already cached (same size): render a thumbnail from disk
        // without re-downloading. The original is kept for the 24h TTL.
        if type == .image {
            let cached = (try? mediaPath.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            if cached == Int(entry.size) {
                if let box = await ThumbnailLoader.load(at: mediaPath, type: .image) {
                    saveThumb(box.image, at: thumb)
                    let thumbBytes = Int64((try? thumb.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    accountForAddedBytes(thumbBytes)
                    return box.image
                }
                // Corrupt original that happens to match the size (crash
                // mid-promote, ENOSPC truncation): drop the cache file and
                // fall through to a fresh download instead of failing forever.
                try? FileManager.default.removeItem(at: mediaPath)
            }
        }

        // Slow path: needs a download. Acquire a limited slot and yield to any
        // user-initiated (foreground) transfer so thumbnails never starve it.
        await acquireThumbnailSlot(client: client)
        defer { releaseThumbnailSlot() }
        guard !Task.isCancelled else { return nil }

        let ok = await client.downloadBackground(remotePath: remotePath, entry: entry, to: mediaPath)
        guard ok, !Task.isCancelled else { return nil }
        guard let box = await ThumbnailLoader.load(at: mediaPath, type: type) else {
            return nil
        }
        // Persist the rendered thumbnail (KB-scale) and keep the original for
        // the 24h TTL — re-visiting the folder then renders from disk instead
        // of re-downloading. trimCache enforces both the TTL and total cap.
        saveThumb(box.image, at: thumb)
        let thumbBytes = Int64((try? thumb.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        accountForAddedBytes(entry.size + thumbBytes)
        return box.image
    }

    /// Retained bytes change only in `fetchThumbnail` (new original + new
    /// thumbnail). Account for them and, when the cap trips, run the full
    /// trim (directory scan + LRU) and resync the counter.
    private func accountForAddedBytes(_ added: Int64) {
        cachedBytes += added
        if cachedBytes > maxTotalSize {
            trimCache()
            cachedBytes = cacheSize()
        }
    }

    private func acquireThumbnailSlot(client: FileClient) async {
        // Yield *before* taking a concurrency slot so foreground transfers are
        // not blocked by thumbnails holding slots while sleeping.
        while client.hasForegroundTransfer {
            try? await Task.sleep(for: .milliseconds(150))
        }
        while active >= maxConcurrent {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiters.append(c)
            }
        }
        active += 1
        // Re-check after acquire — a user transfer may have started while we waited.
        while client.hasForegroundTransfer {
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func releaseThumbnailSlot() {
        active -= 1
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        }
    }

    /// Cancel all in-flight thumbnail downloads (e.g. on directory navigation).
    /// Prevents a previous folder's thumbs from clogging the transport after leave.
    func cancelInflight() {
        for (_, task) in inflight { task.cancel() }
        inflight.removeAll()
        // Unblock anyone waiting for a slot; they will re-check cancellation.
        // Keep `active` as-is: in-flight tasks still hold slots and release
        // them on completion — zeroing it here would double-decrement when
        // those tasks finish and let the next folder burst past maxConcurrent.
        let pending = waiters
        waiters.removeAll()
        for w in pending { w.resume() }
    }

    // MARK: - Paths

    /// Stable cache key from the remote path (path + name hash). Survives
    /// list refreshes and is unique across directories (entry.id is name-only).
    private func cacheKey(for remotePath: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in remotePath.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private func mediaPath(cacheKey: String, name: String) -> URL {
        cacheDir.appendingPathComponent("\(cacheKey)_\(name)")
    }

    /// Thumbnail cache identity includes remote size + modified time so an
    /// overwritten same-name file (size or content change) gets a fresh
    /// render instead of a stale one.
    private func thumbPath(cacheKey: String, name: String, size: Int64, modified: Date) -> URL {
        let ms = Int64(modified.timeIntervalSince1970 * 1_000)
        return cacheDir.appendingPathComponent("\(cacheKey)_\(name)_\(size)_\(ms)_thumb.jpg")
    }

    // MARK: - Thumbnail persistence

    /// Loader output is already small (image/video ≤512px, PDF ≤200px), so the
    /// JPEG is saved as-is: ~10–80KB per cached thumbnail.
    private func saveThumb(_ image: NSImage, at url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return }
        guard let jpeg = rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.75]
        ) else { return }
        try? jpeg.write(to: url)
    }

    // MARK: - Eviction

    /// Call on app launch. Deletes files past their TTL — rendered thumbnails
    /// (KB-scale) live 7 days, full-size originals 24h as a re-render source —
    /// then LRU-evicts until total cache size is under the cap.
    func trimCache() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }

        var totalSize: Int64 = 0
        var survivors: [(url: URL, date: Date, size: Int64)] = []

        for url in entries {
            let attrs = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = attrs?.contentModificationDate ?? .distantPast
            let size = Int64(attrs?.fileSize ?? 0)

            let isThumb = url.lastPathComponent.hasSuffix("_thumb.jpg")
            let ttl: TimeInterval = isThumb ? 7 * 24 * 3600 : 24 * 3600
            let cutoff = Date().addingTimeInterval(-ttl)

            if date < cutoff {
                try? FileManager.default.removeItem(at: url)
            } else {
                totalSize += size
                survivors.append((url, date, size))
            }
        }

        guard totalSize > maxTotalSize else { return }

        survivors.sort { $0.date < $1.date }
        for item in survivors {
            try? FileManager.default.removeItem(at: item.url)
            totalSize -= item.size
            if totalSize <= maxTotalSize { break }
        }
    }

    @MainActor func clearAll() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil) else { return }
        for url in entries { try? FileManager.default.removeItem(at: url) }
        cachedBytes = 0
    }

    nonisolated func cacheSize() -> Int64 {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return entries.reduce(Int64(0)) { acc, url in
            let attrs = try? url.resourceValues(forKeys: [.fileSizeKey])
            return acc + Int64(attrs?.fileSize ?? 0)
        }
    }
}
