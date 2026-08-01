import Foundation
import Combine

@MainActor
final class FileClient: ObservableObject {

    var deviceSerial: String?

    @Published var entries: [DirEntry] = [] {
        didSet { recomputeVisible() }
    }
    @Published var currentPath: String = "/"
    @Published var isLoading: Bool = false
    /// True while fetching a different folder (previous listing may still be on screen).
    @Published private(set) var isNavigating: Bool = false
    @Published var error: String?

    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false

    @Published var showHidden: Bool = UserDefaults.standard.bool(forKey: "sort.showHidden") {
        didSet {
            UserDefaults.standard.set(showHidden, forKey: "sort.showHidden")
            recomputeVisible()
        }
    }

    enum SortKey: String, CaseIterable {
        case name, size, modified
    }
    @Published var sortKey: SortKey = SortKey(rawValue: UserDefaults.standard.string(forKey: "sort.key") ?? "name") ?? .name {
        didSet {
            UserDefaults.standard.set(sortKey.rawValue, forKey: "sort.key")
            recomputeVisible()
        }
    }
    @Published var sortAscending: Bool = (UserDefaults.standard.object(forKey: "sort.ascending") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(sortAscending, forKey: "sort.ascending")
            recomputeVisible()
        }
    }

    enum FilterType: String, CaseIterable {
        case all, images, videos, audio, documents
    }
    @Published var filterType: FilterType = .all {
        didSet {
            filterDebounceTask?.cancel()
            filterDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                recomputeVisible()
            }
        }
    }
    private var filterDebounceTask: Task<Void, Never>?

    @Published var searchQuery: String = "" {
        didSet {
            searchDebounceTask?.cancel()
            if searchQuery.isEmpty {
                recomputeVisible()
            } else {
                searchDebounceTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    recomputeVisible()
                }
            }
        }
    }
    private var searchDebounceTask: Task<Void, Never>?

    @Published private(set) var visibleEntries: [DirEntry] = []
    private(set) var visibleByID: [DirEntry.ID: DirEntry] = [:]

    /// True while a large directory is filter/sorted off the main thread.
    @Published private(set) var isRecomputingVisible: Bool = false

    /// Bumped when pinned paths change so sidebar refreshes without a full path change.
    @Published private(set) var pinEpoch: UInt = 0

    let transferEngine = TransferEngine()
    private var bag: Set<AnyCancellable> = []

    /// Coarse busy flag only (start/stop). Progress ticks live on `transferEngine`
    /// so the file list does not re-render on every chunk.
    @Published private(set) var isTransferring: Bool = false

    /// Folders this large get a soft UX tip (search/filter) and lighter thumbnail load.
    static let largeFolderThreshold = 1_500

    init() {
        // Do NOT forward transferEngine.objectWillChange — progress updates
        // would rebuild the entire FileBrowserView / List.
        transferEngine.$isTransferring
            .receive(on: DispatchQueue.main)
            .sink { [weak self] busy in self?.isTransferring = busy }
            .store(in: &bag)
    }

    var hasForegroundTransfer: Bool { transferEngine.hasForegroundTransfer }
    var lastCompletedTransfer: CompletedTransfer? {
        get { transferEngine.lastCompletedTransfer }
        set { transferEngine.lastCompletedTransfer = newValue }
    }

    // MARK: - File clipboard (device-side copy/cut/paste)

    struct ClipboardEntry: Identifiable {
        let id = UUID()
        let name: String
        let sourcePath: String
    }
    @Published var clipboardEntries: [ClipboardEntry] = []
    @Published var clipboardMode: ClipboardMode = .copy
    @Published var clipboardSourcePath: String = ""
    enum ClipboardMode { case copy, cut }

    /// True when the clipboard has items ready to paste.
    var canPaste: Bool { !clipboardEntries.isEmpty }

    func bind(transport: TransportClient) {
        transferEngine.bind(transport: transport)
    }

    func dismissError() { error = nil }
    func clearCompletedTransfer() { transferEngine.lastCompletedTransfer = nil }

    func toggleSort(_ key: SortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = key == .name
        }
    }

    /// Bumps when a new recompute is scheduled; stale async results are dropped.
    private var visibleGeneration: Int = 0
    private var recomputeTask: Task<Void, Never>?

    private func recomputeVisible() {
        recomputeTask?.cancel()
        visibleGeneration += 1
        let gen = visibleGeneration

        let snapshot = entries
        let showHidden = self.showHidden
        let filterType = self.filterType
        let searchQuery = self.searchQuery
        let sortKey = self.sortKey
        let sortAscending = self.sortAscending

        // Small lists: stay sync to avoid empty-frame flicker on normal folders.
        if snapshot.count < 256 {
            isRecomputingVisible = false
            let sorted = Self.computeVisible(
                entries: snapshot,
                showHidden: showHidden,
                filterType: filterType,
                searchQuery: searchQuery,
                sortKey: sortKey,
                sortAscending: sortAscending
            )
            visibleEntries = sorted
            visibleByID = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0) })
            return
        }

        isRecomputingVisible = true
        recomputeTask = Task(priority: .userInitiated) {
            let sorted = Self.computeVisible(
                entries: snapshot,
                showHidden: showHidden,
                filterType: filterType,
                searchQuery: searchQuery,
                sortKey: sortKey,
                sortAscending: sortAscending
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard gen == self.visibleGeneration else { return }
                self.visibleEntries = sorted
                self.visibleByID = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0) })
                self.isRecomputingVisible = false
            }
        }
    }

    /// Pure filter+sort; safe off the main actor (DirEntry is value-typed).
    nonisolated private static func computeVisible(
        entries: [DirEntry],
        showHidden: Bool,
        filterType: FilterType,
        searchQuery: String,
        sortKey: SortKey,
        sortAscending: Bool
    ) -> [DirEntry] {
        var filtered = showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
        // Hide upload partials (internal resume markers, not user files).
        filtered = filtered.filter { !$0.name.hasSuffix(".droidmate-partial") }
        if filterType != .all {
            filtered = filtered.filter { entry in
                switch filterType {
                case .all: return true
                case .images: return entry.mime.hasPrefix("image/")
                case .videos: return entry.mime.hasPrefix("video/")
                case .audio: return entry.mime.hasPrefix("audio/")
                case .documents: return entry.mime.hasPrefix("text/") || entry.mime == "application/pdf"
                }
            }
        }
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            filtered = filtered.filter { $0.name.lowercased().contains(q) }
        }
        return sorted(filtered, by: sortKey, ascending: sortAscending)
    }

    nonisolated private static func sorted(_ entries: [DirEntry], by key: SortKey, ascending: Bool) -> [DirEntry] {
        entries.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir && !b.isDir }
            let ordered: Bool
            switch key {
            case .name:     ordered = a.name.lowercased() < b.name.lowercased()
            case .size:     ordered = a.size < b.size
            case .modified: ordered = a.modified < b.modified
            }
            return ascending ? ordered : !ordered
        }
    }

    // MARK: - Navigation

    /// Monotonic generation for in-flight listDir calls. Rapid folder switches
    /// must ignore stale responses so an older list can't overwrite a newer one.
    private var listGeneration: Int = 0

    /// - Returns: `true` when a real directory listing was applied (not missing / not a file / not superseded).
    @discardableResult
    func list(path: String) async -> Bool {
        let target = normalize(path)
        // Re-clicking the same sidebar location: soft refresh only (no path flash).
        if target == currentPath {
            return await refresh()
        }
        let applied = await performList(path: target, isNavigation: true)
        guard applied else { return false }
        if historyIndex < history.count - 1 {
            history = Array(history.prefix(historyIndex + 1))
        }
        history.append(target)
        historyIndex = history.count - 1
        updateNavFlags()
        return true
    }

    @discardableResult
    func refresh() async -> Bool {
        await performList(path: currentPath, isNavigation: false)
    }

    func goBack() async {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        let applied = await performList(path: history[historyIndex], isNavigation: true)
        if applied { updateNavFlags() }
    }

    func goForward() async {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        let applied = await performList(path: history[historyIndex], isNavigation: true)
        if applied { updateNavFlags() }
    }

    func goUp() async {
        let p = parent(of: currentPath)
        if p != currentPath { await list(path: p) }
    }

    /// Jump to an absolute Android path (or bare shortcut like `Download`).
    /// Returns false if the path is empty / invalid / missing / not a directory.
    @discardableResult
    func jumpToPath(_ raw: String) async -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Reject path traversal abuse and null bytes.
        guard !trimmed.contains("\0") else { return false }
        let target = normalize(trimmed)
        return await list(path: target)
    }

    private var history: [String] = ["/"]
    private var historyIndex: Int = 0

    private func updateNavFlags() {
        canGoBack = historyIndex > 0
        canGoForward = historyIndex < history.count - 1
    }

    /// - Returns: `true` if this call still owns the UI (not superseded by a
    ///   newer navigation). Callers should skip history updates when `false`.
    /// - Parameter isNavigation: true when changing folders (sidebar/breadcrumb).
    ///   Keeps the previous listing on screen until the new one arrives, and
    ///   applies the result without SwiftUI list diff animations (avoids flash).
    @discardableResult
    private func performList(path: String, isNavigation: Bool = false) async -> Bool {
        listGeneration += 1
        let gen = listGeneration
        let pathChanged = path != currentPath
        currentPath = path
        // Only show the empty-folder skeleton when we have nothing to display yet.
        // Keep previous entries visible during navigation to prevent list flicker.
        if entries.isEmpty {
            isLoading = true
            isNavigating = false
        } else {
            isLoading = false
            isNavigating = isNavigation || pathChanged
        }
        if pathChanged || isNavigation {
            ThumbnailCache.shared.cancelInflight()
        }
        let result = await transferEngine.listDir(path: path)
        // A newer list() started while we were awaiting — drop this result.
        guard gen == listGeneration else { return false }
        self.isLoading = false
        self.isNavigating = false

        // Timeout / no transport: DirListResult.missing (reqId == 0). Stay quiet —
        // session recovery banner covers connectivity; don't cry "not found".
        if result.reqId == 0 && !result.exists {
            if entries.isEmpty { self.entries = [] }
            return false
        }

        // Server answered: distinguish empty folder vs missing vs file-as-path.
        if !result.exists {
            self.entries = []
            self.error = String(localized: "Folder not found — \(path)")
            return false
        }
        if !result.isDir {
            self.entries = []
            self.error = String(localized: "Not a folder — \(path)")
            return false
        }

        // Keep previous listing visible until this assignment; List/Grid disable
        // animations via `.transaction { $0.animation = nil }` + `.id(path)`.
        self.entries = result.entries
        self.error = nil
        rememberPath(path)
        return true
    }

    // MARK: - Per-device last / recent paths

    private static func lastPathKey(for serial: String) -> String {
        "path.last.\(serial)"
    }

    private static func recentPathsKey(for serial: String) -> String {
        "path.recent.\(serial)"
    }

    private static let maxRecentPaths = 6

    private func rememberPath(_ path: String) {
        guard let serial = deviceSerial, !serial.isEmpty else { return }
        let normalized = normalize(path)
        UserDefaults.standard.set(normalized, forKey: Self.lastPathKey(for: serial))
        // Recent list (MRU), skip root-only noise when deeper paths exist later.
        var recent = UserDefaults.standard.stringArray(forKey: Self.recentPathsKey(for: serial)) ?? []
        recent.removeAll { $0 == normalized }
        recent.insert(normalized, at: 0)
        if recent.count > Self.maxRecentPaths {
            recent = Array(recent.prefix(Self.maxRecentPaths))
        }
        UserDefaults.standard.set(recent, forKey: Self.recentPathsKey(for: serial))
    }

    /// Restore the last folder browsed on this device (if any). Call once at
    /// session start before the first listDir.
    func restoreLastPath() {
        guard let serial = deviceSerial,
              let saved = UserDefaults.standard.string(forKey: Self.lastPathKey(for: serial)),
              !saved.isEmpty else { return }
        currentPath = normalize(saved)
        history = [currentPath]
        historyIndex = 0
        updateNavFlags()
    }

    /// Recently visited folders on this device (most recent first), excluding
    /// the current path and bare root duplicates of the shortcuts list.
    func recentPaths(excludingCurrent: Bool = true) -> [String] {
        guard let serial = deviceSerial else { return [] }
        let raw = UserDefaults.standard.stringArray(forKey: Self.recentPathsKey(for: serial)) ?? []
        return raw.filter { path in
            if excludingCurrent && path == currentPath { return false }
            return true
        }
    }

    func removeRecentPath(_ path: String) {
        guard let serial = deviceSerial else { return }
        let p = normalize(path)
        var recent = UserDefaults.standard.stringArray(forKey: Self.recentPathsKey(for: serial)) ?? []
        recent.removeAll { $0 == p }
        UserDefaults.standard.set(recent, forKey: Self.recentPathsKey(for: serial))
        pinEpoch &+= 1 // sidebar observes pinEpoch for favorites; reuse for recent refresh
    }

    func clearRecentPaths() {
        guard let serial = deviceSerial else { return }
        UserDefaults.standard.removeObject(forKey: Self.recentPathsKey(for: serial))
        pinEpoch &+= 1
    }

    // MARK: - Pinned favorites (per device)

    private static func pinnedPathsKey(for serial: String) -> String {
        "path.pinned.\(serial)"
    }

    private static let maxPinnedPaths = 12

    func pinnedPaths() -> [String] {
        guard let serial = deviceSerial else { return [] }
        _ = pinEpoch // establish dependency for observers reading pins
        return UserDefaults.standard.stringArray(forKey: Self.pinnedPathsKey(for: serial)) ?? []
    }

    func isPinned(_ path: String) -> Bool {
        let p = normalize(path)
        return pinnedPaths().contains(p)
    }

    func togglePinned(_ path: String) {
        guard let serial = deviceSerial, !serial.isEmpty else { return }
        let p = normalize(path)
        var list = UserDefaults.standard.stringArray(forKey: Self.pinnedPathsKey(for: serial)) ?? []
        if let idx = list.firstIndex(of: p) {
            list.remove(at: idx)
        } else {
            list.insert(p, at: 0)
            if list.count > Self.maxPinnedPaths {
                list = Array(list.prefix(Self.maxPinnedPaths))
            }
        }
        UserDefaults.standard.set(list, forKey: Self.pinnedPathsKey(for: serial))
        pinEpoch &+= 1
    }

    func removePinned(_ path: String) {
        guard let serial = deviceSerial else { return }
        let p = normalize(path)
        var list = UserDefaults.standard.stringArray(forKey: Self.pinnedPathsKey(for: serial)) ?? []
        list.removeAll { $0 == p }
        UserDefaults.standard.set(list, forKey: Self.pinnedPathsKey(for: serial))
        pinEpoch &+= 1
    }

    // MARK: - Path helpers

    func components(of path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    func child(of path: String, name: String) -> String {
        let p = normalize(path)
        return p == "/" ? name : "\(p)/\(name)"
    }

    /// Absolute on-device path under `/sdcard` (server storage root) for pasteboards / shell.
    func absoluteDevicePath(relative: String) -> String {
        let p = normalize(relative)
        if p == "/" { return "/sdcard" }
        return "/sdcard/\(p)"
    }

    private func normalize(_ p: String) -> String {
        if p.isEmpty || p == "/" { return "/" }
        var stack: [String] = []
        for part in p.split(separator: "/") {
            switch part {
            case ".", "": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(String(part))
            }
        }
        return stack.isEmpty ? "/" : stack.joined(separator: "/")
    }

    private func parent(of path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count <= 1 { return "/" }
        return parts.dropLast().joined(separator: "/")
    }

    // MARK: - Transfer orchestration

    func download(entry: DirEntry, to localURL: URL) async {
        _ = await downloadAndWait(entry: entry, to: localURL)
    }

    /// One automatic retry on failure (default on). Partial files resume from offset.
    private var autoRetryEnabled: Bool {
        UserDefaults.standard.object(forKey: "transfer.auto_retry") as? Bool ?? true
    }

    @discardableResult
    func downloadAndWait(entry: DirEntry, to localURL: URL) async -> Bool {
        let path = child(of: currentPath, name: entry.name)
        return await downloadAndWait(remotePath: path, entry: entry, to: localURL)
    }

    @discardableResult
    func downloadAndWait(remotePath: String, entry: DirEntry, to localURL: URL) async -> Bool {
        return await downloadRemoteWithRetry(remotePath: remotePath, to: localURL, entry: entry)
    }

    /// Shared by single-file and recursive folder downloads.
    private func downloadRemoteWithRetry(remotePath: String, to localURL: URL, entry: DirEntry) async -> Bool {
        var currentEntry = entry
        if transferEngine.hasDownloadPartial(for: localURL) {
            guard let refreshed = await refreshedEntry(remotePath: remotePath) else { return false }
            currentEntry = refreshed
        }
        let first = await transferEngine.download(remotePath: remotePath, to: localURL, entry: currentEntry)
        if first { return true }
        guard !transferEngine.consumeExplicitDownloadCancellation(for: localURL),
              !Task.isCancelled,
              autoRetryEnabled else { return false }
        // Brief pause so a flaky link / adb blip can settle; partial resume applies.
        do {
            try await Task.sleep(for: .milliseconds(700))
        } catch {
            return false
        }
        guard !Task.isCancelled else { return false }
        guard let refreshed = await refreshedEntry(remotePath: remotePath) else { return false }
        return await transferEngine.download(remotePath: remotePath, to: localURL, entry: refreshed)
    }

    private func refreshedEntry(remotePath: String) async -> DirEntry? {
        let name = remotePath.split(separator: "/").last.map(String.init) ?? remotePath
        return await transferEngine.listDir(path: parent(of: remotePath)).entries.first { $0.name == name }
    }

    /// Background download with an explicit remote path (for thumbnail
    /// generation): captures the path at request time so navigation during a
    /// queued fetch can't corrupt it, and tags the transfer as background so
    /// it yields to user-initiated transfers.
    @discardableResult
    func downloadBackground(remotePath: String, entry: DirEntry, to localURL: URL) async -> Bool {
        await transferEngine.download(remotePath: remotePath, to: localURL, entry: entry, background: true)
    }

    func upload(localURL: URL) async {
        let destinationRoot = currentPath
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir)
        if isDir.boolValue {
            await uploadDirectory(
                localURL,
                basePath: child(of: destinationRoot, name: localURL.lastPathComponent)
            )
        } else {
            let destPath = child(of: destinationRoot, name: localURL.lastPathComponent)
            _ = await transferEngine.uploadFile(at: localURL, destPath: destPath)
        }
        // Wait until server ack finished, then show the new files without a manual refresh.
        await refresh()
    }

    /// Upload many items then refresh once (avoids N listDir round-trips).
    /// Top-level files run with bounded concurrency; directories stay sequential
    /// (each dir already parallelizes its files).
    /// - Parameter renameMap: optional local basename → remote basename (Keep Both).
    func uploadMany(_ urls: [URL], renameMap: [String: String] = [:]) async {
        guard !urls.isEmpty else { return }
        let destinationRoot = currentPath
        let jobs = makeUploadJobs(urls, renameMap: renameMap, destinationRoot: destinationRoot)
        let fileJobs = jobs.filter { !$0.isDirectory }
        let directoryJobs = jobs.filter(\.isDirectory)
        _ = await TransferEngine.runBounded(fileJobs) { [self] job in
            await self.transferEngine.uploadFile(at: job.localURL, destPath: job.destPath)
        }
        for job in directoryJobs {
            await uploadDirectory(job.localURL, basePath: job.destPath)
        }
        await refresh()
    }

    struct UploadJob: Equatable, Sendable {
        let localURL: URL
        let destPath: String
        let isDirectory: Bool
    }

    func makeUploadJobs(
        _ urls: [URL],
        renameMap: [String: String] = [:],
        destinationRoot: String
    ) -> [UploadJob] {
        var jobs: [UploadJob] = []
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let remoteName = renameMap[url.lastPathComponent] ?? url.lastPathComponent
            jobs.append(UploadJob(
                localURL: url,
                destPath: child(of: destinationRoot, name: remoteName),
                isDirectory: isDir.boolValue
            ))
        }
        return jobs
    }

    private func uploadDirectory(
        _ dir: URL,
        basePath: String
    ) async {
        // Always create the folder root (empty folders would otherwise be no-ops).
        _ = await transferEngine.mkdir(path: basePath)

        guard let urls = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )?.compactMap({ $0 as? URL }) else { return }

        // Ensure every subfolder exists (including empty leaves). Server mkdir is
        // mkdir -p / idempotent. Sort by depth so parents land first.
        let dirRelPaths: [String] = urls.compactMap { url in
            var isSubDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isSubDir)
            guard isSubDir.boolValue else { return nil }
            let rel = String(url.path.dropFirst(dir.path.count).dropFirst())
            return rel.isEmpty ? nil : rel
        }
        .sorted { $0.split(separator: "/").count < $1.split(separator: "/").count }

        for rel in dirRelPaths {
            _ = await transferEngine.mkdir(path: child(of: basePath, name: rel))
        }

        let fileURLs = urls.filter { url in
            var isSubDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isSubDir)
            return !isSubDir.boolValue
        }
        struct UploadJob: Sendable {
            let fileURL: URL
            let destPath: String
        }
        let jobs: [UploadJob] = fileURLs.map { fileURL in
            let relPath = fileURL.path.dropFirst(dir.path.count).dropFirst()
            return UploadJob(fileURL: fileURL, destPath: child(of: basePath, name: String(relPath)))
        }
        _ = await TransferEngine.runBounded(jobs) { [self] job in
            await self.transferEngine.uploadFile(at: job.fileURL, destPath: job.destPath)
        }
    }

    func cancelTransfer(_ reqId: Int) { transferEngine.cancelTransfer(reqId) }
    func cancelAllTransfers() { transferEngine.cancelAllTransfers() }
    func handleTransportInterruption(reason: String) {
        transferEngine.handleTransportInterruption(reason: reason)
    }

    /// Pause active transfers. Downloads keep resumable partials; uploads restart.
    func pauseAllTransfers() { transferEngine.cancelAllTransfers() }

    /// Re-run a history record. Downloads may resume; uploads restart from byte zero.
    @discardableResult
    func retryTransfer(_ record: TransferRecord) async -> Bool {
        switch record.direction {
        case .download:
            guard let entry = record.entry, let url = record.destinationURL else { return false }
            if let remote = record.remotePath {
                return await downloadRemoteWithRetry(remotePath: remote, to: url, entry: entry)
            }
            return await downloadAndWait(entry: entry, to: url)
        case .upload:
            guard let local = record.destinationURL,
                  let dest = record.remotePath,
                  FileManager.default.fileExists(atPath: local.path) else { return false }
            return await transferEngine.uploadFile(at: local, destPath: dest)
        }
    }

    /// Recursively downloads a device folder to `destDir`, preserving the
    /// internal folder structure. Used by drag-out (drag a folder to Finder).
    /// Walks the tree first, then downloads every file with bounded concurrency
    /// so deep trees are not serialized folder-by-folder.
    /// Returns true only if the remote directory exists and every file succeeds.
    func downloadDirectory(remotePath: String, to destDir: URL) async -> Bool {
        struct Job: Sendable {
            let remotePath: String
            let dest: URL
            let entry: DirEntry
        }
        // DIR_ENTRY carries exists/is_dir for the listed path — empty folder
        // succeeds; missing path does not.
        guard await remoteDirectoryExists(remotePath) else { return false }

        var jobs: [Job] = []

        func collect(remote: String, local: URL) async {
            let listed = await transferEngine.listDir(path: remote)
            try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            for entry in listed.entries {
                let subRemote = child(of: remote, name: entry.name)
                let subLocal = local.appendingPathComponent(entry.name)
                if entry.isDir {
                    await collect(remote: subRemote, local: subLocal)
                } else {
                    jobs.append(Job(remotePath: subRemote, dest: subLocal, entry: entry))
                }
            }
        }

        await collect(remote: remotePath, local: destDir)
        // Empty existing directory: no files to pull — success.
        if jobs.isEmpty { return true }
        return await TransferEngine.runBounded(jobs) { [self] job in
            await self.downloadRemoteWithRetry(remotePath: job.remotePath, to: job.dest, entry: job.entry)
        }
    }

    /// True when `path` is the storage root or an existing directory on the device.
    /// Uses DIR_ENTRY `exists` + `is_dir` (one listDir on the path itself).
    func remoteDirectoryExists(_ path: String) async -> Bool {
        let p = normalize(path)
        if p == "/" { return true }
        let listed = await transferEngine.listDir(path: p)
        return listed.exists && listed.isDir
    }

    // MARK: - File operations (Data Channel FS mutations)

    func delete(names: [String]) async {
        let paths = names.map { child(of: currentPath, name: $0) }
        guard !paths.isEmpty else { return }
        isLoading = true
        let results = await transferEngine.delete(paths: paths)
        let failures = results.filter { !$0.success }
        if !failures.isEmpty {
            let detail = failures.map { "\(($0.path as NSString).lastPathComponent): \($0.error ?? "failed")" }
                .joined(separator: "; ")
            self.error = String(localized: "Delete failed — \(detail)")
        }
        await refresh()
        isLoading = false
    }

    func rename(from oldName: String, to newName: String) async {
        let from = child(of: currentPath, name: oldName)
        let to = child(of: currentPath, name: newName)
        isLoading = true
        let result = await transferEngine.rename(from: from, to: to)
        if !result.success {
            self.error = result.error.map { String(localized: "Rename failed — \($0)") }
                ?? String(localized: "Rename failed")
        }
        await refresh()
        isLoading = false
    }

    func makeDirectory(name: String) async {
        let path = child(of: currentPath, name: name)
        isLoading = true
        let result = await transferEngine.mkdir(path: path)
        if !result.success {
            self.error = result.error.map { String(localized: "New folder failed — \($0)") }
                ?? String(localized: "New folder failed")
        }
        await refresh()
        isLoading = false
    }

    /// Duplicate entries in the current folder via Data Channel FS_COPY.
    /// Names follow Finder style: `photo copy.jpg`, `photo copy 2.jpg`, …
    func duplicate(names: [String]) async {
        guard !names.isEmpty else { return }
        isLoading = true
        var existing = Set(entries.map(\.name))
        var firstError: String?
        for name in names {
            let destName = NameConflict.copyName(name, among: existing)
            existing.insert(destName)
            let from = child(of: currentPath, name: name)
            let to = child(of: currentPath, name: destName)
            let result = await transferEngine.copy(from: from, to: to)
            if !result.success {
                firstError = result.error ?? String(localized: "Duplicate failed")
            }
        }
        if let firstError {
            self.error = String(localized: "Duplicate failed — \(firstError)")
        }
        await refresh()
        isLoading = false
    }

    // MARK: - Copy / Cut / Paste (device-side via Data Channel)

    func copySelected(_ names: [String]) {
        let entries = names.map { ClipboardEntry(name: $0, sourcePath: child(of: currentPath, name: $0)) }
        guard !entries.isEmpty else { return }
        clipboardEntries = entries
        clipboardMode = .copy
        clipboardSourcePath = currentPath
    }

    func cutSelected(_ names: [String]) {
        let entries = names.map { ClipboardEntry(name: $0, sourcePath: child(of: currentPath, name: $0)) }
        guard !entries.isEmpty else { return }
        clipboardEntries = entries
        clipboardMode = .cut
        clipboardSourcePath = currentPath
    }

    func clearClipboard() {
        clipboardEntries = []
    }

    /// Pastes clipboard entries into the current directory.
    /// Copy → Data Channel FS_COPY; cut → FS_RENAME (move).
    /// Name collisions get a numeric suffix ("file 2.ext").
    func paste() async {
        guard !clipboardEntries.isEmpty else { return }
        let mode = clipboardMode
        let items = clipboardEntries
        var takenNames = Set(self.entries.map { $0.name })
        let pairs: [(source: String, dest: String)] = items.map { entry in
            var destName = entry.name
            if takenNames.contains(destName) {
                destName = Self.uniqueName(destName, taken: takenNames)
            }
            takenNames.insert(destName)
            return (entry.sourcePath, child(of: currentPath, name: destName))
        }
        isLoading = true
        var firstError: String?
        for pair in pairs {
            let result: FSOpResult
            switch mode {
            case .copy:
                result = await transferEngine.copy(from: pair.source, to: pair.dest)
            case .cut:
                result = await transferEngine.rename(from: pair.source, to: pair.dest)
            }
            if !result.success, firstError == nil {
                firstError = result.error ?? "failed"
            }
        }
        if let firstError {
            self.error = String(localized: "Paste failed — \(firstError)")
        } else if mode == .cut {
            clipboardEntries = []
        }
        await refresh()
        isLoading = false
    }

    private static func uniqueName(_ name: String, taken: Set<String>) -> String {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var i = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            if !taken.contains(candidate) { return candidate }
            i += 1
        }
    }
}
