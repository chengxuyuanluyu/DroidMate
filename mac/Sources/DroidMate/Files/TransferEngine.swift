import Foundation
import Combine
import UserNotifications
import UniformTypeIdentifiers

@MainActor
final class TransferEngine: ObservableObject, @unchecked Sendable {

    /// Bound for parallel file upload/download workers (directory + multi-select).
    static let maxConcurrentFileTransfers = 4
    /// Local Mac paths — process-global so two sessions cannot clobber the same file.
    private static var activeDownloadDestinations: Set<String> = []
    /// On-device paths — per TransferEngine (per DeviceSession) so two phones can
    /// upload to the same remote path string without false "destination busy".
    private var activeUploadDestinations: Set<String> = []

    private static func downloadDestinationKey(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func uploadDestinationKey(_ destPath: String) -> String {
        destPath
    }

    static func claimDownloadDestination(_ url: URL) -> String? {
        let key = downloadDestinationKey(url)
        return activeDownloadDestinations.insert(key).inserted ? key : nil
    }

    static func releaseDownloadDestination(_ key: String) {
        activeDownloadDestinations.remove(key)
    }

    func claimUploadDestination(_ path: String) -> String? {
        let key = (path as NSString).standardizingPath
        return activeUploadDestinations.insert(key).inserted ? key : nil
    }

    func releaseUploadDestination(_ key: String) {
        activeUploadDestinations.remove(key)
    }

    func hasDownloadPartial(for localURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: localURL.appendingPathExtension("droidmate-partial").path
        )
    }

    @Published var isTransferring: Bool = false
    @Published var lastCompletedTransfer: CompletedTransfer?
    @Published private(set) var transferSpeedMBps: Double = 0
    @Published private(set) var transfers: [TransferItem] = []
    @Published private(set) var transferHistory: [TransferRecord] = []
    /// Aggregate byte counters for the active batch (status bar ETA / summary).
    @Published private(set) var transferBytesDone: Int64 = 0
    @Published private(set) var transferBytesTotal: Int64 = 0

    /// User-visible (foreground) transfers in flight. Thumbnail downloads are
    /// excluded so the queue summary, dock badge, and batch counts stay in
    /// sync with what the progress bar shows.
    var activeTransferCount: Int {
        pendingDownloads.values.filter { !$0.background }.count + pendingUploads.count
    }

    /// Run `body` over `items` with at most `limit` concurrent tasks.
    /// Returns false if any body returns false (still drains the rest).
    static func runBounded<T: Sendable>(
        _ items: [T],
        limit: Int = maxConcurrentFileTransfers,
        body: @escaping @Sendable @MainActor (T) async -> Bool
    ) async -> Bool {
        guard !items.isEmpty else { return true }
        let cap = max(1, limit)
        return await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            var iterator = items.makeIterator()
            var allOk = true
            var inFlight = 0
            func enqueue() {
                while inFlight < cap, let item = iterator.next() {
                    inFlight += 1
                    group.addTask {
                        await body(item)
                    }
                }
            }
            enqueue()
            for await ok in group {
                inFlight -= 1
                if !ok { allOk = false }
                enqueue()
            }
            return allOk
        }
    }

    /// Files finished in the current batch (resets when a new batch starts).
    var batchCompletedCount: Int { doneCount }

    /// Total files in the current batch (completed + still active).
    var batchTotalCount: Int { doneCount + activeTransferCount }

    var activeTransferName: String? {
        let n = activeTransferCount
        if n == 0 { return nil }
        let current: String = {
            if let d = pendingDownloads.values.first(where: { !$0.background }) { return d.entryName }
            if let u = pendingUploads.values.first { return u.localURL.lastPathComponent }
            return ""
        }()
        let total = batchTotalCount
        if total <= 1 { return current.isEmpty ? nil : current }
        // "2/5 · photo.jpg" so multi-file batches stay scannable.
        let index = min(doneCount + 1, total)
        if current.isEmpty {
            return String(localized: "\(index)/\(total) files")
        }
        return String(localized: "\(index)/\(total) · \(current)")
    }

    /// Remaining time estimate based on current speed, or nil if unknown.
    var estimatedRemainingSeconds: Double? {
        guard transferSpeedMBps > 0.05, transferBytesTotal > transferBytesDone else { return nil }
        let left = Double(transferBytesTotal - transferBytesDone)
        let bps = transferSpeedMBps * 1_000_000
        guard bps > 0 else { return nil }
        return left / bps
    }

    private var _transferProgress: Double = 0
    var transferProgress: Double { _transferProgress }

    /// Count of user-initiated (foreground) transfers in flight. Thumbnail
    /// downloads are tagged `background` and excluded, so the thumbnail
    /// scheduler can tell when the transport is free of user work.
    private var foregroundCount = 0
    var hasForegroundTransfer: Bool { foregroundCount > 0 }

    private weak var transport: TransportClient?
    private var nextReqId: Int = 1
    private var pendingListReqs: [Int: CheckedContinuation<DirListResult, Never>] = [:]
    private var pendingDownloads: [Int: DownloadState] = [:]
    private var pendingUploads: [Int: UploadState] = [:]
    private var pendingDownloadConts: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var downloadStartSendTasks: [Int: Task<Bool, Never>] = [:]
    private var uploadStartSendTasks: [Int: Task<Bool, Never>] = [:]
    private var explicitlyCancelledDownloadDestinations: Set<String> = []
    /// Upload destinations explicitly cancelled by the user, keyed like
    /// download markers so batch aggregation can tell "user paused" apart
    /// from "actually failed" (no failure banner for user cancels).
    private var explicitlyCancelledUploadDestinations: Set<String> = []
    private var downloadTimeoutTasks: [Int: Task<Void, Never>] = [:]
    private var pendingUploadConts: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var pendingDeleteConts: [Int: CheckedContinuation<[FSPathResult], Never>] = [:]
    private var pendingDeletePaths: [Int: [String]] = [:]
    private var pendingOpConts: [Int: CheckedContinuation<FSOpResult, Never>] = [:]

    private var lastProgressEmit: Double = 0
    private var lastProgressEmitTime: Date = .distantPast
    private var speedLastBytes: Int64 = 0
    private var speedLastTime: Date = .distantPast
    /// Last computed speed; only copied into @Published `transferSpeedMBps` on UI emit.
    private var pendingSpeedMBps: Double = 0

    private var doneCount: Int = 0
    private var doneBytes: Int64 = 0
    private var lastDoneName: String = ""
    private var lastDoneURL: URL?
    /// Set when a foreground transfer completes while background work is still
    /// in flight, so the batch notification fires when the queue finally drains
    /// — even if the *last* transfer to finish was a thumbnail download.
    private var foregroundBatchNeedsNotification = false
    private let maxHistoryCount = 50
    /// Device serial bound to persisted history; nil until a session restores.
    private var historySerial: String?
    private let downloadInactivityTimeout: Duration

    init(downloadInactivityTimeout: Duration = .seconds(60)) {
        self.downloadInactivityTimeout = downloadInactivityTimeout
    }

    func bind(transport: TransportClient) {
        self.transport = transport
        transport.setFilesHandler { [weak self] frame in
            await self?.handle(frame)
        }
    }

    // MARK: - List

    /// Lists `path` on the device. Result includes `exists`/`isDir` for the
    /// requested path (empty folder ≠ missing). Without transport, or on
    /// timeout, returns a missing result (`exists == false`).
    func listDir(path: String) async -> DirListResult {
        guard let transport else { return .missing }
        let reqId = nextReqId
        nextReqId += 1
        let payload: [String: Any] = ["req_id": reqId, "path": path]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return .missing
        }
        let frame = encodeFrame(streamId: StreamId.files, msgType: MsgType.listDir, payload: data)
        return await withCheckedContinuation { cont in
            pendingListReqs[reqId] = cont
            Task { @MainActor in
                guard await transport.send(frame) else {
                    pendingListReqs.removeValue(forKey: reqId)?.resume(returning: .missing)
                    return
                }
                // Safety net: if the server never replies (or a parse failure
                // drops it), don't hang the file browser.
                try? await Task.sleep(for: .seconds(15))
                if let c = pendingListReqs.removeValue(forKey: reqId) {
                    c.resume(returning: .missing)
                }
            }
        }
    }

    // MARK: - FS mutations (Data Channel)

    /// Delete one or more absolute device paths (recursive for directories).
    func delete(paths: [String]) async -> [FSPathResult] {
        guard let transport, !paths.isEmpty else {
            return paths.map { FSPathResult(path: $0, success: false, error: "no transport") }
        }
        let reqId = nextReqId
        nextReqId += 1
        let body = FSDeleteRequest(reqId: reqId, paths: paths)
        guard let data = try? WireJSON.encoder.encode(body) else {
            return paths.map { FSPathResult(path: $0, success: false, error: "encode failed") }
        }
        let frame = encodeFrame(streamId: StreamId.files, msgType: MsgType.fsDelete, payload: data)
        return await withCheckedContinuation { cont in
            pendingDeleteConts[reqId] = cont
            pendingDeletePaths[reqId] = paths
            Task { @MainActor in
                guard await transport.send(frame) else {
                    pendingDeletePaths.removeValue(forKey: reqId)
                    pendingDeleteConts.removeValue(forKey: reqId)?.resume(returning: paths.map {
                        FSPathResult(
                            path: $0,
                            success: false,
                            error: String(localized: "Connection unavailable")
                        )
                    })
                    return
                }
                try? await Task.sleep(for: .seconds(30))
                if let c = pendingDeleteConts.removeValue(forKey: reqId) {
                    pendingDeletePaths.removeValue(forKey: reqId)
                    c.resume(returning: paths.map {
                        FSPathResult(path: $0, success: false, error: "timeout")
                    })
                }
            }
        }
    }

    /// Rename/move `from` → `to` on the device filesystem.
    func rename(from: String, to: String) async -> FSOpResult {
        await fsOp(msgType: MsgType.fsRename, body: FSRenameRequest(reqId: 0, from: from, to: to))
    }

    /// Copy `from` → `to` (recursive for directories).
    func copy(from: String, to: String) async -> FSOpResult {
        await fsOp(msgType: MsgType.fsCopy, body: FSCopyRequest(reqId: 0, from: from, to: to))
    }

    /// Create directory at `path` (`mkdir -p` semantics).
    func mkdir(path: String) async -> FSOpResult {
        await fsOp(msgType: MsgType.fsMkdir, body: FSMkdirRequest(reqId: 0, path: path))
    }

    private func fsOp<T: Encodable>(msgType: UInt16, body: T) async -> FSOpResult {
        guard let transport else {
            return FSOpResult(reqId: 0, success: false, error: "no transport")
        }
        let reqId = nextReqId
        nextReqId += 1
        // Rebuild JSON with assigned req_id (bodies are constructed with placeholder 0).
        var dict: [String: Any]
        if let data = try? WireJSON.encoder.encode(body),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = obj
        } else {
            return FSOpResult(reqId: reqId, success: false, error: "encode failed")
        }
        dict["req_id"] = reqId
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else {
            return FSOpResult(reqId: reqId, success: false, error: "encode failed")
        }
        let frame = encodeFrame(streamId: StreamId.files, msgType: msgType, payload: data)
        return await withCheckedContinuation { cont in
            pendingOpConts[reqId] = cont
            Task { @MainActor in
                guard await transport.send(frame) else {
                    pendingOpConts.removeValue(forKey: reqId)?.resume(returning: FSOpResult(
                        reqId: reqId,
                        success: false,
                        error: String(localized: "Connection unavailable")
                    ))
                    return
                }
                try? await Task.sleep(for: .seconds(30))
                if let c = pendingOpConts.removeValue(forKey: reqId) {
                    c.resume(returning: FSOpResult(reqId: reqId, success: false, error: "timeout"))
                }
            }
        }
    }

    // MARK: - Download

    @discardableResult
    func download(remotePath: String, to localURL: URL, entry: DirEntry, background: Bool = false) async -> Bool {
        // Background (thumbnail) work yields the Data Channel to user transfers
        // before any transport check so waiters do not spin-fail while busy.
        if background {
            while hasForegroundTransfer {
                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch {
                    return false
                }
            }
        }
        guard !Task.isCancelled else { return false }

        guard let transport else { return false }
        guard let destinationClaim = Self.claimDownloadDestination(localURL) else { return false }
        defer { Self.releaseDownloadDestination(destinationClaim) }
        explicitlyCancelledDownloadDestinations.remove(destinationClaim)

        let reqId = nextReqId
        nextReqId += 1

        // Resume support: stream to a .droidmate-partial file, promoted to the
        // final destination only on success. A leftover partial from a previous
        // interrupted attempt lets us resume from where it stopped.
        let partialURL = localURL.appendingPathExtension("droidmate-partial")
        guard let partial = prepareDownloadPartial(
            partialURL: partialURL,
            remotePath: remotePath,
            entry: entry
        ) else { return false }
        let startOffset = partial.offset
        let identity = DownloadIdentity(remotePath: remotePath, entry: entry)
        var payload: [String: Any] = [
            "req_id": reqId,
            "path": remotePath,
            "expected_size": identity.size,
            "expected_modified": identity.modifiedMilliseconds,
        ]
        if startOffset > 0 { payload["offset"] = startOffset }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        guard let state = DownloadState(
            localURL: localURL,
            partialURL: partialURL,
            entryName: entry.name,
            entry: entry,
            remotePath: remotePath,
            totalBytes: entry.size,
            startOffset: startOffset,
            metadataURL: partial.metadataURL,
            background: background
        ) else {
            return false
        }
        pendingDownloads[reqId] = state
        let frame = encodeFrame(streamId: StreamId.files, msgType: MsgType.downloadStart, payload: data)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                pendingDownloadConts[reqId] = cont
                // Register the waiter and START ordering point before publishing
                // an active transfer. A synchronous UI observer may cancel from
                // that publication; it must either suppress START entirely or
                // wait until START has been accepted before sending CANCEL.
                let startSendTask = Task { @MainActor in
                    guard pendingDownloads[reqId] != nil else { return false }
                    return await transport.send(frame)
                }
                downloadStartSendTasks[reqId] = startSendTask
                // A new foreground batch starts only when this is the first
                // foreground transfer in flight; thumbnail downloads don't
                // count and must not clear the batch counters.
                let isFirstForeground = !background && foregroundCount == 0
                if !background { foregroundCount += 1 }
                // `isTransferring` drives user-facing chrome (status bar,
                // queue summary, button disabling). Background thumbnail
                // downloads must not flip it on — browsing a large folder
                // would otherwise pin the progress bar at 100% until every
                // thumbnail finishes.
                if !background { isTransferring = true }
                if isFirstForeground { doneCount = 0; doneBytes = 0 }
                recomputeProgress(force: true)
                lastCompletedTransfer = nil
                Task { @MainActor in
                    let sent = await startSendTask.value
                    downloadStartSendTasks.removeValue(forKey: reqId)
                    guard sent else {
                        if pendingDownloads[reqId] != nil {
                            failTransfer(reqId, message: String(localized: "Connection unavailable"))
                        }
                        return
                    }
                    guard pendingDownloads[reqId] != nil else { return }
                    scheduleDownloadTimeout(reqId)
                }
            }
        } onCancel: { [self] in
            Task { @MainActor [self] in cancelTransfer(reqId) }
        }
    }

    /// Test seam: simulate an active foreground transfer (S2 scheduling).
    func setForegroundCountForTesting(_ count: Int) {
        foregroundCount = max(0, count)
    }

    /// Reuse a partial only when it belongs to the exact remote file revision.
    private func prepareDownloadPartial(
        partialURL: URL,
        remotePath: String,
        entry: DirEntry
    ) -> (offset: Int64, metadataURL: URL)? {
        let metadataURL = partialURL.appendingPathExtension("json")
        let expected = DownloadIdentity(remotePath: remotePath, entry: entry)
        let fm = FileManager.default

        if fm.fileExists(atPath: partialURL.path),
           let data = try? Data(contentsOf: metadataURL),
           let saved = try? JSONDecoder().decode(DownloadIdentity.self, from: data),
           saved == expected,
           let attrs = try? fm.attributesOfItem(atPath: partialURL.path),
           let size = attrs[.size] as? Int64,
           size > 0,
           size < entry.size {
            return (size, metadataURL)
        }

        try? fm.removeItem(at: partialURL)
        try? fm.removeItem(at: metadataURL)
        do {
            try JSONEncoder().encode(expected).write(to: metadataURL, options: .atomic)
            return (0, metadataURL)
        } catch {
            return nil
        }
    }

    // MARK: - Upload

    @discardableResult
    func uploadFile(at localURL: URL, destPath: String) async -> Bool {
        guard let transport else { return false }
        // A fresh upload attempt clears any stale "user cancelled" marker.
        explicitlyCancelledUploadDestinations.remove(Self.uploadDestinationKey(destPath))
        guard let sourceRevision = UploadSourceRevision(url: localURL) else { return false }
        let size = sourceRevision.size
        let modified = Int64(sourceRevision.modified.timeIntervalSince1970)
        let fileName = localURL.lastPathComponent

        let reqId = nextReqId
        nextReqId += 1
        guard let destinationClaim = claimUploadDestination(destPath) else {
            transferHistory.insert(TransferRecord(
                id: reqId,
                name: fileName,
                bytes: 0,
                direction: .upload,
                status: .failed,
                timestamp: Date(),
                errorMessage: String(localized: "Another upload is already using this destination"),
                entry: nil,
                destinationURL: localURL,
                remotePath: destPath
            ), at: 0)
            trimHistory()
            return false
        }
        defer { releaseUploadDestination(destinationClaim) }
        guard let startData = Self.freshUploadStartPayload(
            reqId: reqId,
            destPath: destPath,
            size: size,
            modified: modified,
            mime: mimeForPath(fileName)
        ) else { return false }
        pendingUploads[reqId] = UploadState(
            totalBytes: size,
            sent: 0,
            localURL: localURL,
            destPath: destPath
        )

        guard let fh = try? FileHandle(forReadingFrom: localURL) else {
            failTransfer(reqId, message: String(localized: "Couldn’t open the local file"))
            return false
        }
        let startFrame = encodeFrame(streamId: StreamId.files, msgType: MsgType.uploadStart, payload: startData)

        // Register the ACK waiter before the first byte leaves this process.
        // A fast peer may acknowledge uploadComplete before send() returns.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                pendingUploadConts[reqId] = cont
                let startSendTask = Task { @MainActor in
                    guard let state = pendingUploads[reqId], !state.isCancelling else { return false }
                    return await transport.send(startFrame)
                }
                uploadStartSendTasks[reqId] = startSendTask
                isTransferring = true
                // Uploads never run in the background: the first upload with no
                // foreground download in flight opens a new batch.
                if pendingUploads.count == 1 && foregroundCount == 0 {
                    doneCount = 0
                    doneBytes = 0
                }
                // Uploads are always foreground work — count them (after the
                // batch-reset check above) so `isTransferring` mirrors every
                // user-visible transfer.
                if let state = pendingUploads[reqId] {
                    state.didCountForeground = true
                    foregroundCount += 1
                }
                recomputeProgress(force: true)
                lastCompletedTransfer = nil

                Task { @MainActor in
                    defer { try? fh.close() }
                    let started = await startSendTask.value
                    uploadStartSendTasks.removeValue(forKey: reqId)
                    guard started else {
                        if let state = pendingUploads[reqId], !state.isCancelling {
                            failTransfer(reqId, message: String(localized: "Connection unavailable"))
                        }
                        return
                    }

                    let chunkSize = 64 * 1024
                    var offset: UInt64 = 0
                    while true {
                        guard let state = pendingUploads[reqId],
                              !state.isCancelling,
                              !state.isCommitting else { return }
                        let chunk = fh.readData(ofLength: chunkSize)
                        if chunk.isEmpty { break }
                        var payload = Data(capacity: 16 + chunk.count)
                        payload.append(UInt8(reqId & 0xFF))
                        payload.append(UInt8((reqId >> 8) & 0xFF))
                        payload.append(UInt8((reqId >> 16) & 0xFF))
                        payload.append(UInt8((reqId >> 24) & 0xFF))
                        var value = offset
                        for _ in 0..<8 { payload.append(UInt8(value & 0xFF)); value >>= 8 }
                        let length = UInt32(chunk.count)
                        payload.append(UInt8(length & 0xFF))
                        payload.append(UInt8((length >> 8) & 0xFF))
                        payload.append(UInt8((length >> 16) & 0xFF))
                        payload.append(UInt8((length >> 24) & 0xFF))
                        payload.append(chunk)
                        let dataFrame = encodeFrame(
                            streamId: StreamId.files,
                            msgType: MsgType.uploadData,
                            payload: payload
                        )
                        guard await transport.send(dataFrame) else {
                            failTransfer(reqId, message: String(localized: "Connection unavailable"))
                            return
                        }
                        offset += UInt64(chunk.count)
                        pendingUploads[reqId]?.sent = Int64(offset)
                        recomputeProgress()
                    }

                    let sourceUnchanged = offset == UInt64(size)
                        && UploadSourceRevision(url: localURL) == sourceRevision
                    guard sourceUnchanged else {
                        _ = await sendUploadAbort(reqId)
                        if pendingUploads[reqId] != nil {
                            failTransfer(reqId, message: String(localized: "Local file changed — upload stopped"))
                        }
                        return
                    }

                    let complete: [String: Any] = [
                        "req_id": reqId,
                        "size": size,
                        "modified": modified,
                        "mime": mimeForPath(fileName),
                        "dest_path": destPath,
                    ]
                    guard let data = try? JSONSerialization.data(withJSONObject: complete) else {
                        _ = await sendUploadAbort(reqId)
                        failTransfer(reqId, message: String(localized: "Couldn’t finish the upload"))
                        return
                    }
                    let completeFrame = encodeFrame(
                        streamId: StreamId.files,
                        msgType: MsgType.uploadComplete,
                        payload: data
                    )
                    guard let state = pendingUploads[reqId], !state.isCancelling else { return }
                    // COMPLETE is the irreversible boundary. Once queued, the UI
                    // shows this row as finishing and no longer offers cancel.
                    state.isCommitting = true
                    recomputeProgress(force: true)
                    guard await transport.send(completeFrame) else {
                        failTransfer(reqId, message: String(localized: "Connection unavailable"))
                        return
                    }

                    // Wait for the server ACK so callers only refresh after the
                    // destination file is actually committed.
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(60))
                        if pendingUploadConts[reqId] != nil {
                            failTransfer(reqId, message: String(localized: "Upload timed out"))
                        }
                    }
                }
            }
        } onCancel: { [self] in
            Task { @MainActor [self] in cancelTransfer(reqId) }
        }
    }

    /// Uploads always start from byte zero until the wire protocol binds a
    /// device-side partial to this exact local file revision.
    static func freshUploadStartPayload(
        reqId: Int,
        destPath: String,
        size: Int64,
        modified: Int64,
        mime: String
    ) -> Data? {
        try? JSONSerialization.data(withJSONObject: [
            "req_id": reqId,
            "dest_path": destPath,
            "size": size,
            "modified": modified,
            "mime": mime,
        ])
    }

    // MARK: - Cancel

    func cancelTransfer(_ reqId: Int) {
        if let download = pendingDownloads[reqId] {
            explicitlyCancelledDownloadDestinations.insert(Self.downloadDestinationKey(download.localURL))
            sendDownloadCancel(reqId)
            finishTransfer(
                reqId,
                status: .cancelled,
                message: cancellationMessage(isDownload: true)
            )
            return
        }
        if let upload = pendingUploads[reqId] {
            guard !upload.isCommitting, !upload.isCancelling else { return }
            upload.isCancelling = true
            explicitlyCancelledUploadDestinations.insert(Self.uploadDestinationKey(upload.destPath))
            recomputeProgress(force: true)
            Task { @MainActor in
                _ = await sendUploadAbort(reqId)
                if pendingUploads[reqId]?.isCancelling == true {
                    finishTransfer(
                        reqId,
                        status: .cancelled,
                        message: cancellationMessage(isDownload: false)
                    )
                }
            }
        }
    }

    private func cancellationMessage(isDownload: Bool) -> String {
        String(localized: isDownload
            ? "Paused / cancelled — partial kept for resume"
            : "Paused / cancelled — upload restarts from the beginning")
    }

    private func sendDownloadCancel(_ reqId: Int) {
        guard let transport,
              let payload = try? JSONSerialization.data(withJSONObject: ["req_id": reqId]) else { return }
        let frame = encodeFrame(
            streamId: StreamId.files,
            msgType: MsgType.downloadCancel,
            payload: payload
        )
        let startSendTask = downloadStartSendTasks[reqId]
        Task {
            if let startSendTask, await !startSendTask.value { return }
            _ = await transport.send(frame)
        }
    }

    private func sendUploadAbort(_ reqId: Int) async -> Bool {
        guard let transport,
              let payload = try? JSONSerialization.data(withJSONObject: ["req_id": reqId]) else {
            return false
        }
        if let startSendTask = uploadStartSendTasks[reqId], await !startSendTask.value {
            return false
        }
        return await transport.send(encodeFrame(
            streamId: StreamId.files,
            msgType: MsgType.uploadAbort,
            payload: payload
        ))
    }

    func consumeExplicitDownloadCancellation(for localURL: URL) -> Bool {
        explicitlyCancelledDownloadDestinations.remove(Self.downloadDestinationKey(localURL)) != nil
    }

    /// Non-consuming check — used by the retry decision so the marker stays
    /// available for the batch aggregator to distinguish cancel from failure.
    func isExplicitlyCancelledDownload(for localURL: URL) -> Bool {
        explicitlyCancelledDownloadDestinations.contains(Self.downloadDestinationKey(localURL))
    }

    /// Batch aggregators consume the marker: a user-cancelled upload is not a
    /// failure and must not raise the "N uploads failed" banner.
    func consumeExplicitUploadCancellation(for destPath: String) -> Bool {
        explicitlyCancelledUploadDestinations.remove(Self.uploadDestinationKey(destPath)) != nil
    }

    private func failTransfer(_ reqId: Int, message: String) {
        if pendingDownloads[reqId] != nil {
            sendDownloadCancel(reqId)
        }
        finishTransfer(reqId, status: .failed, message: message)
    }

    private func finishTransfer(_ reqId: Int, status: TransferRecord.Status, message: String) {
        downloadTimeoutTasks.removeValue(forKey: reqId)?.cancel()
        let dl = pendingDownloads.removeValue(forKey: reqId)
        let ul = pendingUploads.removeValue(forKey: reqId)
        // Keep the .droidmate-partial so an interrupted download can resume later.
        dl?.finish()
        if let dl, !dl.background { foregroundCount = max(0, foregroundCount - 1) }
        if let ul, ul.didCountForeground { foregroundCount = max(0, foregroundCount - 1) }
        if let cont = pendingDownloadConts.removeValue(forKey: reqId) {
            cont.resume(returning: false)
        }
        if let cont = pendingUploadConts.removeValue(forKey: reqId) {
            cont.resume(returning: false)
        }
        // Background (thumbnail) downloads stay out of the user-visible batch:
        // cancelling them mid-navigation must not write "Paused" history rows.
        if dl != nil || ul != nil, dl?.background != true {
            transferHistory.insert(TransferRecord(
                id: reqId,
                name: dl?.entryName ?? ul?.localURL.lastPathComponent ?? "Unknown",
                bytes: dl?.received ?? ul?.sent ?? 0,
                direction: dl != nil ? .download : .upload,
                status: status,
                timestamp: Date(),
                errorMessage: message,
                entry: dl?.entry,
                destinationURL: dl?.localURL ?? ul?.localURL,
                remotePath: dl?.remotePath ?? ul?.destPath
            ), at: 0)
            trimHistory()
        }
        // Only the user's foreground batch owns the "transferring" chrome.
        // Background thumbnails finishing after a batch must not extend the
        // progress bar or delay the completion notification.
        if foregroundCount == 0 {
            if isTransferring {
                isTransferring = false
                recomputeProgress(force: true)
            }
            // A batch whose tail ended in cancel / timeout / send failure
            // still surfaces the completed part (mirrors the ACK handlers).
            if doneCount > 0 && foregroundBatchNeedsNotification {
                foregroundBatchNeedsNotification = false
                lastCompletedTransfer = makeCompletedTransfer(direction: dl != nil ? .download : .upload)
                sendCompletionNotification()
            }
        }
    }

    func cancelAllTransfers(explicit: Bool = true) {
        for id in Array(pendingDownloads.keys) + Array(pendingUploads.keys) {
            if explicit {
                cancelTransfer(id)
            } else {
                finishTransfer(
                    id,
                    status: .cancelled,
                    message: cancellationMessage(isDownload: pendingDownloads[id] != nil)
                )
            }
        }
    }

    /// Resolve every waiter immediately when the socket disappears. Active
    /// transfers are paused so their partial files remain resumable.
    func handleTransportInterruption(reason: String) {
        let listWaiters = Array(pendingListReqs.values)
        pendingListReqs.removeAll()
        listWaiters.forEach { $0.resume(returning: .missing) }

        let deleteWaiters = pendingDeleteConts
        pendingDeleteConts.removeAll()
        for (reqId, cont) in deleteWaiters {
            let paths = pendingDeletePaths.removeValue(forKey: reqId) ?? []
            cont.resume(returning: paths.map {
                FSPathResult(path: $0, success: false, error: reason)
            })
        }

        let opWaiters = pendingOpConts
        pendingOpConts.removeAll()
        for (reqId, cont) in opWaiters {
            cont.resume(returning: FSOpResult(reqId: reqId, success: false, error: reason))
        }
        cancelAllTransfers(explicit: false)
    }

    func clearHistory() {
        transferHistory = []
        persistHistory()
    }

    /// Drop completed successes; keep failed/paused so Retry stays useful.
    func clearCompletedHistory() {
        transferHistory.removeAll { $0.status == .completed }
        persistHistory()
    }

    /// Loads persisted history for a device session and binds future writes
    /// to that serial. Also bumps the request-id generator so fresh transfers
    /// never collide with restored history rows in the queue UI.
    func restoreHistory(serial: String) {
        historySerial = serial
        transferHistory = TransferHistoryStore.load(serial: serial)
        nextReqId = (transferHistory.map(\.id).max() ?? 0) + 1
    }

    /// Test seam: replace history contents.
    func replaceHistoryForTesting(_ records: [TransferRecord]) {
        transferHistory = records
    }

    /// Test seam: expose the request-id generator (restoreHistory collision check).
    var nextRequestIDForTesting: Int { nextReqId }

    // MARK: - Inbound

    private func handle(_ frame: Frame) async {
        switch frame.msgType {
        case MsgType.dirEntry:        await handleDirEntry(frame.payload)
        case MsgType.uploadComplete:  handleUploadComplete(frame.payload)
        case MsgType.downloadStart:   handleDownloadStart(frame.payload)
        case MsgType.downloadData:    handleDownloadData(frame.payload)
        case MsgType.downloadComplete:handleDownloadComplete(frame.payload)
        case MsgType.fsDeleteResult:  handleFSDeleteResult(frame.payload)
        case MsgType.fsRenameResult, MsgType.fsMkdirResult, MsgType.fsCopyResult:
            handleFSOpResult(frame.payload)
        default: break
        }
    }

    private func handleFSDeleteResult(_ payload: Data) {
        guard let result = try? WireJSON.decoder.decode(FSDeleteResult.self, from: payload) else { return }
        pendingDeletePaths.removeValue(forKey: result.reqId)
        if let cont = pendingDeleteConts.removeValue(forKey: result.reqId) {
            cont.resume(returning: result.results)
        }
    }

    private func handleFSOpResult(_ payload: Data) {
        guard let result = try? WireJSON.decoder.decode(FSOpResult.self, from: payload) else { return }
        if let cont = pendingOpConts.removeValue(forKey: result.reqId) {
            cont.resume(returning: result)
        }
    }

    /// Test seam: inject an inbound files-stream frame (S2).
    func handleInboundForTesting(_ frame: Frame) async {
        await handle(frame)
    }

    /// Test seam: register a pending delete waiter, run `body` (should inject result), return results.
    func withPendingDeleteForTesting(
        reqId: Int,
        paths: [String] = [],
        body: @escaping () async -> Void
    ) async -> [FSPathResult] {
        await withCheckedContinuation { cont in
            pendingDeleteConts[reqId] = cont
            pendingDeletePaths[reqId] = paths
            Task { await body() }
        }
    }

    /// Test seam: register a pending rename/mkdir waiter, run `body`, return op result.
    func withPendingOpForTesting(reqId: Int, body: @escaping () async -> Void) async -> FSOpResult {
        await withCheckedContinuation { cont in
            pendingOpConts[reqId] = cont
            Task { await body() }
        }
    }

    /// Test seam: exercise download frames and on-disk commit without a socket.
    func withPendingDownloadForTesting(
        reqId: Int,
        localURL: URL,
        entry: DirEntry,
        startOffset: Int64 = 0,
        background: Bool = true,
        body: @escaping () async -> Void
    ) async -> Bool {
        let partialURL = localURL.appendingPathExtension("droidmate-partial")
        guard let state = DownloadState(
            localURL: localURL,
            partialURL: partialURL,
            entryName: entry.name,
            entry: entry,
            remotePath: "/sdcard/\(entry.name)",
            totalBytes: entry.size,
            startOffset: startOffset,
            metadataURL: partialURL.appendingPathExtension("json"),
            background: background
        ) else { return false }
        pendingDownloads[reqId] = state
        return await withCheckedContinuation { cont in
            pendingDownloadConts[reqId] = cont
            scheduleDownloadTimeout(reqId)
            Task { await body() }
        }
    }

    /// Test seam for partial-file identity handling.
    func prepareDownloadOffsetForTesting(
        partialURL: URL,
        remotePath: String,
        entry: DirEntry
    ) -> Int64? {
        prepareDownloadPartial(partialURL: partialURL, remotePath: remotePath, entry: entry)?.offset
    }

    private func handleDirEntry(_ payload: Data) async {
        // Parse off the main thread — large directories (thousands of entries)
        // would otherwise stall the UI during JSON decode + date/size formatting.
        let parsed = await Task.detached(priority: .userInitiated) { () -> DirListResult? in
            DirEntry.parseList(payload)
        }.value
        guard let result = parsed else { return }
        if let cont = pendingListReqs.removeValue(forKey: result.reqId) {
            cont.resume(returning: result)
        }
    }

    private func handleUploadComplete(_ payload: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let reqId = json["req_id"] as? Int else { return }
        let upload = pendingUploads.removeValue(forKey: reqId)
        let success = (json["success"] as? Bool) ?? false
        let wasCancelled = upload?.isCancelling == true
        if let upload, upload.didCountForeground { foregroundCount = max(0, foregroundCount - 1) }
        if let cont = pendingUploadConts.removeValue(forKey: reqId) {
            cont.resume(returning: success && !wasCancelled)
        }
        if let upload, success, !wasCancelled {
            doneCount += 1
            doneBytes += upload.totalBytes
            lastDoneName = upload.localURL.lastPathComponent
            foregroundBatchNeedsNotification = true
        }
        if let upload {
            transferHistory.insert(TransferRecord(
                id: reqId, name: upload.localURL.lastPathComponent,
                bytes: success ? upload.totalBytes : upload.sent,
                direction: .upload,
                status: wasCancelled ? .cancelled : (success ? .completed : .failed),
                timestamp: Date(),
                errorMessage: wasCancelled
                    ? cancellationMessage(isDownload: false)
                    : (success ? nil : String(localized: "Upload failed")),
                entry: nil,
                destinationURL: upload.localURL,
                remotePath: upload.destPath
            ), at: 0)
            trimHistory()
        }
        if foregroundCount == 0 {
            if isTransferring {
                isTransferring = false
                recomputeProgress(force: true)
            }
            // Mirrors the download handler: fire once per foreground batch.
            if doneCount > 0 && foregroundBatchNeedsNotification {
                foregroundBatchNeedsNotification = false
                lastCompletedTransfer = makeCompletedTransfer(direction: .upload)
                sendCompletionNotification()
            }
        }
    }

    private func handleDownloadStart(_ payload: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let reqId = json["req_id"] as? Int else { return }
        guard let state = pendingDownloads[reqId] else { return }
        let expected = DownloadIdentity(remotePath: state.remotePath, entry: state.entry)
        guard let size = (json["size"] as? NSNumber)?.int64Value,
              let modified = (json["modified"] as? NSNumber)?.int64Value,
              let offset = (json["offset"] as? NSNumber)?.int64Value,
              size == expected.size,
              modified == expected.modifiedMilliseconds,
              offset == state.received else {
            failTransfer(reqId, message: String(localized: "Remote file changed — retry the download"))
            return
        }
        state.revisionValidated = true
        scheduleDownloadTimeout(reqId)
    }

    private func handleDownloadData(_ payload: Data) {
        guard payload.count >= 4 else { return }
        let reqId = Int(readLE32(payload, at: 0))
        guard let state = pendingDownloads[reqId] else { return }
        guard state.revisionValidated else {
            failTransfer(reqId, message: String(localized: "Transfer failed"))
            return
        }
        guard payload.count >= 16 else {
            failTransfer(reqId, message: String(localized: "Transfer failed"))
            return
        }
        let offset = readLE64(payload, at: 4)
        let length = Int(readLE32(payload, at: 12))
        guard payload.count == 16 + length,
              state.received >= 0,
              offset == UInt64(state.received),
              state.received <= state.totalBytes,
              Int64(length) <= state.totalBytes - state.received else {
            failTransfer(reqId, message: String(localized: "Transfer failed"))
            return
        }
        do {
            try state.write(payload.subdata(in: 16..<(16 + length)))
            scheduleDownloadTimeout(reqId)
            recomputeProgress()
        } catch {
            failTransfer(reqId, message: String(localized: "Transfer failed"))
        }
    }

    private func handleDownloadComplete(_ payload: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let reqId = json["req_id"] as? Int else { return }
        downloadTimeoutTasks.removeValue(forKey: reqId)?.cancel()
        guard let state = pendingDownloads.removeValue(forKey: reqId) else { return }
        let serverOk = (json["success"] as? Bool) ?? false
        let flushed = state.finish()
        if !state.background { foregroundCount = max(0, foregroundCount - 1) }
        // Promote partial → final destination only when the server confirms
        // success AND every expected byte arrived. The byte-count gate guards
        // against a stale partial being promoted after the remote file shrank
        // (resume offset > real size → server streams nothing). On failure the
        // .droidmate-partial is retained so the download can resume.
        let success = serverOk && state.revisionValidated && flushed
            && state.received == state.totalBytes && state.promote()
        if let cont = pendingDownloadConts.removeValue(forKey: reqId) {
            cont.resume(returning: success)
        }
        // Background (thumbnail) downloads never touch the user-visible batch:
        // no history row, no done counter, no completion notification.
        if success && !state.background {
            doneCount += 1
            doneBytes += state.totalBytes
            lastDoneName = state.entryName
            lastDoneURL = state.localURL
            foregroundBatchNeedsNotification = true
        }
        if !state.background {
            transferHistory.insert(TransferRecord(
                id: reqId, name: state.entryName,
                bytes: success ? state.totalBytes : state.received,
                direction: .download,
                status: success ? .completed : .failed,
                timestamp: Date(),
                errorMessage: success ? nil : String(localized: "Transfer failed"),
                entry: state.entry,
                destinationURL: state.localURL,
                remotePath: state.remotePath
            ), at: 0)
            trimHistory()
        }
        if foregroundCount == 0 {
            if isTransferring {
                isTransferring = false
                recomputeProgress(force: true)
            }
            // Fire once per foreground batch, even when a background thumbnail
            // download is the last transfer to drain the queue.
            if doneCount > 0 && foregroundBatchNeedsNotification {
                foregroundBatchNeedsNotification = false
                lastCompletedTransfer = makeCompletedTransfer(direction: .download)
                sendCompletionNotification()
            }
        }
    }

    private func scheduleDownloadTimeout(_ reqId: Int) {
        guard let state = pendingDownloads[reqId] else { return }
        let clock = ContinuousClock()
        state.lastActivity = clock.now
        guard downloadTimeoutTasks[reqId] == nil else { return }
        let timeout = downloadInactivityTimeout
        downloadTimeoutTasks[reqId] = Task { [weak self] in
            while !Task.isCancelled {
                let deadline = state.lastActivity.advanced(by: timeout)
                do {
                    try await clock.sleep(until: deadline)
                } catch {
                    return
                }
                guard let self,
                      let current = self.pendingDownloads[reqId],
                      current === state else { return }
                guard clock.now >= state.lastActivity.advanced(by: timeout) else { continue }
                self.failTransfer(reqId, message: String(localized: "Transfer timed out"))
                return
            }
        }
    }

    // MARK: - Progress

    private func recomputeProgress(force: Bool = false) {
        // Progress reflects the user's foreground batch only. Background
        // (thumbnail) downloads are excluded from both sides, so their
        // completion can't shrink the totals and snap the bar backwards.
        let pendingTotal = pendingDownloads.values
            .filter { !$0.background }
            .reduce(Int64(0)) { $0 + $1.totalBytes } +
            pendingUploads.values.reduce(Int64(0)) { $0 + $1.totalBytes }
        let pendingDone = pendingDownloads.values
            .filter { !$0.background }
            .reduce(Int64(0)) { $0 + $1.received } +
            pendingUploads.values.reduce(Int64(0)) { $0 + $1.sent }
        // Completed bytes join both sides so the aggregate never regresses:
        // finished transfers leave `pending*`, but their bytes stay in totals.
        let total = pendingTotal + doneBytes
        let done  = pendingDone + doneBytes
        let p = total > 0 ? Double(done) / Double(total) : 0

        // Speed tracks only in-flight bytes; completed work is not "speed".
        let now = Date()
        let dt = now.timeIntervalSince(speedLastTime)
        if dt >= 0.3 {
            let db = Double(pendingDone - speedLastBytes)
            // Speed is @Published — only assign when we will also emit UI (below)
            // or store privately until emit.
            speedLastBytes = pendingDone
            speedLastTime = now
            // stash candidate speed for the next UI emit
            pendingSpeedMBps = dt > 0 ? max(0, db / 1_000_000 / dt) : 0
        }

        let big = abs(p - lastProgressEmit) >= 0.005
        let stale = now.timeIntervalSince(lastProgressEmitTime) >= 1.0 / 15
        guard force || big || stale else {
            _transferProgress = p
            return
        }
        lastProgressEmit = p
        lastProgressEmitTime = now

        // Single publish burst (~15 Hz): progress, bytes, speed, row models.
        _transferProgress = p
        transferBytesDone = done
        transferBytesTotal = total
        if pendingSpeedMBps >= 0 {
            transferSpeedMBps = pendingSpeedMBps
        }

        let perSpeed = activeTransferCount > 0 && transferSpeedMBps > 0
            ? transferSpeedMBps / Double(activeTransferCount) : 0
        var items: [TransferItem] = []
        for (reqId, state) in pendingDownloads {
            // Background (thumbnail) downloads stay out of the queue sheet.
            if state.background { continue }
            items.append(TransferItem(
                id: reqId, name: state.entryName,
                progress: state.totalBytes > 0 ? Double(state.received) / Double(state.totalBytes) : 0,
                direction: .download, bytesDone: state.received, bytesTotal: state.totalBytes, speedMBps: perSpeed
            ))
        }
        for (reqId, state) in pendingUploads {
            items.append(TransferItem(
                id: reqId, name: state.localURL.lastPathComponent,
                progress: state.totalBytes > 0 ? Double(state.sent) / Double(state.totalBytes) : 0,
                direction: .upload, bytesDone: state.sent, bytesTotal: state.totalBytes,
                speedMBps: perSpeed, canCancel: !state.isCommitting && !state.isCancelling
            ))
        }
        transfers = items
    }

    private func makeCompletedTransfer(direction: CompletedTransfer.Direction) -> CompletedTransfer {
        CompletedTransfer(
            name: doneCount == 1 ? lastDoneName : "\(doneCount) files",
            bytes: doneBytes,
            direction: direction,
            destinationURL: lastDoneURL
        )
    }

    private func trimHistory() {
        if transferHistory.count > maxHistoryCount {
            transferHistory = Array(transferHistory.prefix(maxHistoryCount))
        }
        persistHistory()
    }

    /// Best-effort write-through to disk; failures keep the in-memory history.
    private func persistHistory() {
        guard let serial = historySerial else { return }
        TransferHistoryStore.save(serial: serial, records: transferHistory)
    }

    private func sendCompletionNotification() {
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        let isDownload = lastCompletedTransfer?.direction == .download
        let name = doneCount == 1 ? lastDoneName : "\(doneCount) files"
        let sizeStr = ByteCountFormatter.string(fromByteCount: doneBytes, countStyle: .file)
        if isDownload {
            content.title = String(localized: "Downloaded \(name)")
            content.body = lastDoneURL != nil
                ? String(localized: "\(sizeStr) — click to show in Finder")
                : sizeStr
        } else {
            content.title = String(localized: "Uploaded \(name)")
            content.body = sizeStr
        }
        content.sound = .default
        content.categoryIdentifier = TransferNotificationCenter.categoryId
        if let path = lastDoneURL?.path {
            content.userInfo = [TransferNotificationCenter.pathKey: path]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func mimeForPath(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext),
              let mime = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mime
    }
}

// MARK: - Data types

struct DirEntry: Identifiable, Equatable, Hashable, Sendable, Codable {
    /// Stable within a directory listing (file name is unique on the device FS).
    /// Avoids UUID-per-parse which broke List identity, selection, and thumb inflight keys on every refresh.
    let id: String
    let name: String
    let size: Int64
    let modified: Date
    let isDir: Bool
    let mime: String
    let sizeText: String
    let dateText: String

    /// Parses a dirEntry payload. Uses local formatters (not a shared
    /// @MainActor cache) so it is safe to call from any thread — used by the
    /// off-main parse path in `TransferEngine.handleDirEntry`.
    static func parseList(_ payload: Data) -> DirListResult? {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let reqId = json["req_id"] as? Int,
              let rawEntries = json["entries"] as? [[String: Any]] else { return nil }
        // Top-level exists/is_dir (path being listed). Absent on older servers —
        // treat as present directory so empty listings still browse.
        let pathExists = json["exists"] as? Bool ?? true
        let pathIsDir = json["is_dir"] as? Bool ?? true
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let bf = ByteCountFormatter()
        bf.countStyle = .file
        let mapped: [DirEntry] = rawEntries.map { e in
            let name = e["name"] as? String ?? ""
            let isDir = e["is_dir"] as? Bool ?? false
            let size = Int64(e["size"] as? Int ?? 0)
            let modified = Date(timeIntervalSince1970: TimeInterval(e["modified"] as? Int ?? 0) / 1000)
            return DirEntry(
                id: name,
                name: name,
                size: size,
                modified: modified,
                isDir: isDir,
                mime: e["mime"] as? String ?? "application/octet-stream",
                sizeText: isDir ? "—" : bf.string(fromByteCount: size),
                dateText: df.string(from: modified)
            )
        }
        return DirListResult(reqId: reqId, exists: pathExists, isDir: pathIsDir, entries: mapped)
    }
}

struct DirListResult: Sendable {
    let reqId: Int
    /// Whether the listed path exists on the device.
    let exists: Bool
    /// Whether the listed path is a directory (`false` for files / missing).
    let isDir: Bool
    let entries: [DirEntry]

    /// No transport / timeout / encode failure — treat as not present.
    static let missing = DirListResult(reqId: 0, exists: false, isDir: false, entries: [])
}

struct TransferItem: Identifiable, Equatable {
    let id: Int
    let name: String
    let progress: Double
    let direction: CompletedTransfer.Direction
    let bytesDone: Int64
    let bytesTotal: Int64
    let speedMBps: Double
    var canCancel: Bool = true
}

struct TransferRecord: Identifiable, Equatable, Codable {
    let id: Int
    let name: String
    let bytes: Int64
    let direction: CompletedTransfer.Direction
    let status: Status
    let timestamp: Date
    let errorMessage: String?
    let entry: DirEntry?
    /// Local path: download destination or upload source.
    let destinationURL: URL?
    /// Device path: download remote path or upload dest path.
    let remotePath: String?
    enum Status: String, Codable { case completed, failed, cancelled }

    /// Can re-run from history (download with entry, or upload with local+remote).
    var canRetry: Bool {
        switch direction {
        case .download:
            return (status == .failed || status == .cancelled)
                && entry != nil && destinationURL != nil
        case .upload:
            return (status == .failed || status == .cancelled)
                && destinationURL != nil && remotePath != nil
                && FileManager.default.fileExists(atPath: destinationURL!.path)
        }
    }
}

struct CompletedTransfer: Equatable {
    enum Direction: String, Codable { case download, upload }
    let name: String
    let bytes: Int64
    let direction: Direction
    let destinationURL: URL?
}

// MARK: - Transfer state (stream chunks to disk; multi-GB never in memory)

private struct DownloadIdentity: Codable, Equatable {
    let remotePath: String
    let size: Int64
    let modifiedMilliseconds: Int64

    init(remotePath: String, entry: DirEntry) {
        self.remotePath = remotePath
        self.size = entry.size
        self.modifiedMilliseconds = Int64((entry.modified.timeIntervalSince1970 * 1_000).rounded())
    }
}

private final class DownloadState {
    let localURL: URL
    let partialURL: URL
    let entryName: String
    let entry: DirEntry
    let remotePath: String
    let metadataURL: URL
    let background: Bool
    var totalBytes: Int64
    var received: Int64
    var revisionValidated = false
    var lastActivity = ContinuousClock().now
    private let handle: FileHandle

    init?(
        localURL: URL,
        partialURL: URL,
        entryName: String,
        entry: DirEntry,
        remotePath: String,
        totalBytes: Int64,
        startOffset: Int64,
        metadataURL: URL,
        background: Bool
    ) {
        self.localURL = localURL
        self.partialURL = partialURL
        self.entryName = entryName
        self.entry = entry
        self.remotePath = remotePath
        self.metadataURL = metadataURL
        self.background = background
        self.totalBytes = totalBytes
        self.received = startOffset
        do {
            if startOffset > 0 {
                // Resume: append only when the partial really matches the requested offset.
                let opened = try FileHandle(forWritingTo: partialURL)
                guard try opened.seekToEnd() == UInt64(startOffset) else {
                    try? opened.close()
                    return nil
                }
                self.handle = opened
            } else {
                // Fresh: atomically create/truncate the partial before opening it.
                try Data().write(to: partialURL, options: .atomic)
                self.handle = try FileHandle(forWritingTo: partialURL)
            }
        } catch {
            return nil
        }
    }

    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        received += Int64(data.count)
    }

    @discardableResult
    func finish() -> Bool {
        do {
            try handle.synchronize()
            try handle.close()
            return true
        } catch {
            try? handle.close()
            return false
        }
    }

    /// Promotes the partial to the final destination. Only call after the
    /// server confirms a complete transfer.
    func promote() -> Bool {
        do {
            if FileManager.default.fileExists(atPath: localURL.path) {
                _ = try FileManager.default.replaceItemAt(localURL, withItemAt: partialURL)
            } else {
                try FileManager.default.moveItem(at: partialURL, to: localURL)
            }
            try? FileManager.default.removeItem(at: metadataURL)
            return true
        } catch {
            return false
        }
    }
}

private final class UploadState {
    let totalBytes: Int64
    var sent: Int64
    let localURL: URL
    let destPath: String
    var isCancelling = false
    var isCommitting = false
    /// True once this upload has incremented `foregroundCount`. The increment
    /// happens inside the ACK waiter, but `failTransfer` (e.g. the local file
    /// cannot be opened) can run before that — the decrement must only fire
    /// when an increment actually happened.
    var didCountForeground = false
    init(totalBytes: Int64, sent: Int64, localURL: URL, destPath: String) {
        self.totalBytes = totalBytes
        self.sent = sent
        self.localURL = localURL
        self.destPath = destPath
    }
}

struct UploadSourceRevision: Equatable, Sendable {
    let size: Int64
    let modified: Date
    let fileNumber: UInt64?

    init?(url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        self.size = size.int64Value
        self.modified = modified
        self.fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}
