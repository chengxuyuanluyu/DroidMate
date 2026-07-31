import Foundation
import AppKit

/// Disk-backed thumbnail cache for image and video files.
///
/// Responsibilities:
///   - Cache path generation (keyed by entry.id + entry.name)
///   - Cache hit detection (size-matched file exists)
///   - Thumbnail generation orchestration (download → decode → cache)
///   - Video-specific flow: generate PNG thumbnail, delete video original
///   - LRU eviction (200 MB cap, 7-day TTL)
///
/// Called by FileGridTile and FileInspectorView — they just call
/// `getThumbnail(for:client:)` and get back an NSImage (or nil).
/// No cache logic lives in the views.
@MainActor
final class ThumbnailCache {

    static let shared = ThumbnailCache()

    private let cacheDir: URL
    private let maxImageBytes: Int64 = 2_000_000
    private let maxVideoBytes: Int64 = 10_000_000
    private let maxPdfBytes: Int64 = 5_000_000
    private var maxTotalSize: Int64 {
        let mb = UserDefaults.standard.object(forKey: "cache.limit_mb") as? Int ?? 200
        return Int64(mb) * 1_000_000
    }

    private init() {
        cacheDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DroidMateThumb", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true)
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

    /// In-flight fetches keyed by entry — concurrent requests for the same
    /// entry share one download (dedup).
    private var inflight: [DirEntry.ID: Task<NSImage?, Never>] = [:]
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

        // Dedup: share an in-flight fetch for the same entry.
        if let task = inflight[entry.id] { return await task.value }

        // Capture the remote path now so navigation during a queued fetch
        // can't redirect the download to the wrong file.
        let remotePath = client.child(of: client.currentPath, name: entry.name)
        let key = cacheKey(for: remotePath)
        let task = Task { @MainActor in
            await self.fetchThumbnail(for: entry, remotePath: remotePath, cacheKey: key, client: client)
        }
        inflight[entry.id] = task
        let result = await task.value
        inflight[entry.id] = nil
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

        // Fast path: cache hits need no concurrency slot.
        if type != .image {
            let thumb = thumbPath(cacheKey: cacheKey, name: entry.name)
            if FileManager.default.fileExists(atPath: thumb.path) {
                return await ThumbnailLoader.load(at: thumb, type: .image)?.image
            }
        }
        if type == .image {
            let cached = (try? mediaPath.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            if cached == Int(entry.size) {
                return await ThumbnailLoader.load(at: mediaPath, type: .image)?.image
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
        if type != .image {
            savePng(box.image, at: thumbPath(cacheKey: cacheKey, name: entry.name))
            try? FileManager.default.removeItem(at: mediaPath)
        }
        return box.image
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
        let pending = waiters
        waiters.removeAll()
        active = 0
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

    private func thumbPath(cacheKey: String, name: String) -> URL {
        cacheDir.appendingPathComponent("\(cacheKey)_\(name)_thumb.png")
    }

    // MARK: - PNG persistence

    private func savePng(_ image: NSImage, at url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    // MARK: - Eviction

    /// Call on app launch. Deletes files older than 7 days, then LRU-evicts
    /// until total cache size is under 200 MB.
    func trimCache() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        var totalSize: Int64 = 0
        var survivors: [(url: URL, date: Date, size: Int64)] = []

        for url in entries {
            let attrs = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = attrs?.contentModificationDate ?? .distantPast
            let size = Int64(attrs?.fileSize ?? 0)

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

    nonisolated func clearAll() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil) else { return }
        for url in entries { try? FileManager.default.removeItem(at: url) }
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
