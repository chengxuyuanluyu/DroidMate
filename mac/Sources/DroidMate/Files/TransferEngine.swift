import Foundation
import Combine
import UserNotifications
import UniformTypeIdentifiers

@MainActor
final class TransferEngine: ObservableObject {

    /// Bound for parallel file upload/download workers (directory + multi-select).
    static let maxConcurrentFileTransfers = 4

    @Published var isTransferring: Bool = false
    @Published var lastCompletedTransfer: CompletedTransfer?
    @Published private(set) var transferSpeedMBps: Double = 0
    @Published private(set) var transfers: [TransferItem] = []
    @Published private(set) var transferHistory: [TransferRecord] = []
    /// Aggregate byte counters for the active batch (status bar ETA / summary).
    @Published private(set) var transferBytesDone: Int64 = 0
    @Published private(set) var transferBytesTotal: Int64 = 0

    var activeTransferCount: Int { pendingDownloads.count + pendingUploads.count }

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
            if let d = pendingDownloads.values.first { return d.entryName }
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
    private var pendingUploadConts: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var pendingDeleteConts: [Int: CheckedContinuation<[FSPathResult], Never>] = [:]
    private var pendingOpConts: [Int: CheckedContinuation<FSOpResult, Never>] = [:]

    private var lastProgressEmit: Double = 0
    private var lastProgressEmitTime: Date = .distantPast
    private var speedLastBytes: Int64 = 0
    private var speedLastTime: Date = .distantPast

    private var doneCount: Int = 0
    private var doneBytes: Int64 = 0
    private var lastDoneName: String = ""
    private var lastDoneURL: URL?
    private let maxHistoryCount = 50

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
        await transport.send(frame)
        return await withCheckedContinuation { cont in
            pendingListReqs[reqId] = cont
            // Safety net: if the server never replies (dropped connection, or a
            // parse failure drops the reply), don't hang the file browser.
            Task { @MainActor in
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
        await transport.send(frame)
        return await withCheckedContinuation { cont in
            pendingDeleteConts[reqId] = cont
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                if let c = pendingDeleteConts.removeValue(forKey: reqId) {
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
        await transport.send(frame)
        return await withCheckedContinuation { cont in
            pendingOpConts[reqId] = cont
            Task { @MainActor in
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
                try? await Task.sleep(for: .milliseconds(150))
            }
        }

        guard let transport else { return false }

        let reqId = nextReqId
        nextReqId += 1

        // Resume support: stream to a .droidmate-partial file, promoted to the
        // final destination only on success. A leftover partial from a previous
        // interrupted attempt lets us resume from where it stopped.
        let partialURL = localURL.appendingPathExtension("droidmate-partial")
        let startOffset = resumeOffset(for: partialURL, totalBytes: entry.size)
        var payload: [String: Any] = ["req_id": reqId, "path": remotePath]
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
            background: background
        ) else {
            return false
        }
        pendingDownloads[reqId] = state
        if !background { foregroundCount += 1 }
        isTransferring = true
        if activeTransferCount == 1 { doneCount = 0; doneBytes = 0 }
        recomputeProgress(force: true)
        lastCompletedTransfer = nil
        let frame = encodeFrame(streamId: StreamId.files, msgType: MsgType.downloadStart, payload: data)
        await transport.send(frame)
        return await withCheckedContinuation { cont in
            pendingDownloadConts[reqId] = cont
        }
    }

    /// Test seam: simulate an active foreground transfer (S2 scheduling).
    func setForegroundCountForTesting(_ count: Int) {
        foregroundCount = max(0, count)
    }

    /// Returns a non-zero resume offset when a valid partial exists and is
    /// strictly smaller than the remote file; otherwise 0 (removes a stale one).
    private func resumeOffset(for partialURL: URL, totalBytes: Int64) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: partialURL.path),
              let size = attrs[.size] as? Int64 else { return 0 }
        if size > 0 && size < totalBytes { return size }
        try? FileManager.default.removeItem(at: partialURL)
        return 0
    }

    // MARK: - Upload

    @discardableResult
    func uploadFile(at localURL: URL, destPath: String, startOffset: UInt64 = 0, autoResume: Bool = true) async -> Bool {
        guard let transport else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path) else { return false }
        let size = (attrs[.size] as? Int64) ?? 0
        let modified = (attrs[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970) } ?? 0
        let fileName = localURL.lastPathComponent

        // Auto-detect a resumable partial on the device (single-file uploads;
        // directory uploads skip this to avoid one listDir round-trip per file).
        var effectiveOffset = startOffset
        if autoResume && startOffset == 0 {
            effectiveOffset = await detectUploadOffset(destPath: destPath, localSize: size)
        }

        let reqId = nextReqId
        nextReqId += 1
        var start: [String: Any] = [
            "req_id": reqId,
            "dest_path": destPath,
            "size": size,
            "modified": modified,
            "mime": mimeForPath(fileName),
        ]
        if effectiveOffset > 0 { start["offset"] = effectiveOffset }
        guard let startData = try? JSONSerialization.data(withJSONObject: start) else { return false }
        pendingUploads[reqId] = UploadState(
            totalBytes: size,
            sent: Int64(effectiveOffset),
            localURL: localURL,
            destPath: destPath
        )
        isTransferring = true
        if activeTransferCount == 1 { doneCount = 0; doneBytes = 0 }
        recomputeProgress(force: true)
        lastCompletedTransfer = nil

        let startFrame = encodeFrame(streamId: StreamId.files, msgType: MsgType.uploadStart, payload: startData)
        await transport.send(startFrame)

        guard let fh = try? FileHandle(forReadingFrom: localURL) else {
            pendingUploads.removeValue(forKey: reqId)
            return false
        }
        defer { try? fh.close() }
        if effectiveOffset > 0 { try? fh.seek(toOffset: effectiveOffset) }
        let chunkSize = 64 * 1024
        var offset: UInt64 = effectiveOffset
        while true {
            // Cancelled mid-stream?
            guard pendingUploads[reqId] != nil else { return false }
            let chunk = fh.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            var frame = Data(capacity: 16 + chunk.count)
            frame.append(UInt8(reqId & 0xFF))
            frame.append(UInt8((reqId >> 8) & 0xFF))
            frame.append(UInt8((reqId >> 16) & 0xFF))
            frame.append(UInt8((reqId >> 24) & 0xFF))
            var v = offset
            for _ in 0..<8 { frame.append(UInt8(v & 0xFF)); v >>= 8 }
            let len = UInt32(chunk.count)
            frame.append(UInt8(len & 0xFF))
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8((len >> 16) & 0xFF))
            frame.append(UInt8((len >> 24) & 0xFF))
            frame.append(chunk)
            let dataFrame = encodeFrame(streamId: StreamId.files, msgType: MsgType.uploadData, payload: frame)
            await transport.send(dataFrame)
            offset += UInt64(chunk.count)
            pendingUploads[reqId]?.sent = Int64(offset)
            recomputeProgress()
        }
        let complete: [String: Any] = ["req_id": reqId, "size": size, "modified": modified, "mime": mimeForPath(fileName), "dest_path": destPath]
        if let data = try? JSONSerialization.data(withJSONObject: complete) {
            let frame = encodeFrame(streamId: StreamId.files, msgType: MsgType.uploadComplete, payload: data)
            await transport.send(frame)
        }
        // Wait for server ACK so callers can refresh the folder when the file is actually on device.
        return await withCheckedContinuation { cont in
            pendingUploadConts[reqId] = cont
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(60))
                if let c = pendingUploadConts.removeValue(forKey: reqId) {
                    c.resume(returning: false)
                }
            }
        }
    }

    func uploadResume(localURL: URL, destPath: String, startOffset: UInt64) async {
        guard startOffset > 0 else {
            _ = await uploadFile(at: localURL, destPath: destPath)
            return
        }
        _ = await uploadFile(at: localURL, destPath: destPath, startOffset: startOffset)
    }

    /// Detects a resumable upload by listing the destination's parent folder.
    /// Looks for a `.droidmate-partial` marker (not the real file), so a
    /// complete-but-different same-named file can never be mistaken for a
    /// partial. Returns the partial size when 0 < it < localSize; else 0.
    func detectUploadOffset(destPath: String, localSize: Int64) async -> UInt64 {
        guard localSize > 0 else { return 0 }
        let parts = destPath.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return 0 }
        let parent = parts.dropLast().joined(separator: "/")
        let partialName = parts.last! + ".droidmate-partial"
        let entries = await listDir(path: parent).entries
        if let existing = entries.first(where: { $0.name == partialName && !$0.isDir }),
           existing.size > 0, existing.size < localSize {
            return UInt64(existing.size)
        }
        return 0
    }

    // MARK: - Cancel

    func cancelTransfer(_ reqId: Int) {
        let dl = pendingDownloads.removeValue(forKey: reqId)
        let ul = pendingUploads.removeValue(forKey: reqId)
        // Keep the .droidmate-partial so an interrupted download can resume later.
        if let dl, !dl.background { foregroundCount -= 1 }
        if let cont = pendingDownloadConts.removeValue(forKey: reqId) {
            cont.resume(returning: false)
        }
        if let cont = pendingUploadConts.removeValue(forKey: reqId) {
            cont.resume(returning: false)
        }
        if dl != nil || ul != nil {
            transferHistory.insert(TransferRecord(
                id: reqId,
                name: dl?.entryName ?? ul?.localURL.lastPathComponent ?? "Unknown",
                bytes: dl?.received ?? ul?.sent ?? 0,
                direction: dl != nil ? .download : .upload,
                status: .cancelled,
                timestamp: Date(),
                errorMessage: String(localized: "Paused / cancelled — partial kept for resume"),
                entry: dl?.entry,
                destinationURL: dl?.localURL ?? ul?.localURL,
                remotePath: dl?.remotePath ?? ul?.destPath
            ), at: 0)
            trimHistory()
        }
        if pendingDownloads.isEmpty && pendingUploads.isEmpty {
            isTransferring = false
            recomputeProgress(force: true)
        }
    }

    func cancelAllTransfers() {
        for id in Array(pendingDownloads.keys) + Array(pendingUploads.keys) {
            cancelTransfer(id)
        }
    }

    func clearHistory() {
        transferHistory = []
    }

    /// Drop completed successes; keep failed/paused so Retry stays useful.
    func clearCompletedHistory() {
        transferHistory.removeAll { $0.status == .completed }
    }

    /// Test seam: replace history contents.
    func replaceHistoryForTesting(_ records: [TransferRecord]) {
        transferHistory = records
    }

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
    func withPendingDeleteForTesting(reqId: Int, body: @escaping () async -> Void) async -> [FSPathResult] {
        await withCheckedContinuation { cont in
            pendingDeleteConts[reqId] = cont
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
        let success = (json["success"] as? Bool) ?? true
        if let cont = pendingUploadConts.removeValue(forKey: reqId) {
            cont.resume(returning: success)
        }
        if let upload, success {
            doneCount += 1
            doneBytes += upload.totalBytes
            lastDoneName = upload.localURL.lastPathComponent
        }
        if let upload {
            transferHistory.insert(TransferRecord(
                id: reqId, name: upload.localURL.lastPathComponent,
                bytes: success ? upload.totalBytes : upload.sent,
                direction: .upload,
                status: success ? .completed : .failed,
                timestamp: Date(),
                errorMessage: success ? nil : String(localized: "Upload failed"),
                entry: nil,
                destinationURL: upload.localURL,
                remotePath: upload.destPath
            ), at: 0)
            trimHistory()
        }
        if pendingUploads.isEmpty && pendingDownloads.isEmpty {
            isTransferring = false
            recomputeProgress(force: true)
            if doneCount > 0 {
                lastCompletedTransfer = makeCompletedTransfer(direction: .upload)
                sendCompletionNotification()
            }
        }
    }

    private func handleDownloadStart(_ payload: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let reqId = json["req_id"] as? Int else { return }
        if let state = pendingDownloads[reqId] {
            if let total = json["size"] as? Int64 { state.totalBytes = total }
        }
    }

    private func handleDownloadData(_ payload: Data) {
        guard payload.count >= 16 else { return }
        let reqId = Int(payload[0]) | (Int(payload[1]) << 8) | (Int(payload[2]) << 16) | (Int(payload[3]) << 24)
        let length = Int(payload[12]) | (Int(payload[13]) << 8) | (Int(payload[14]) << 16) | (Int(payload[15]) << 24)
        guard let state = pendingDownloads[reqId] else { return }
        if payload.count >= 16 + length {
            state.write(payload.subdata(in: 16..<(16 + length)))
            recomputeProgress()
        }
    }

    private func handleDownloadComplete(_ payload: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let reqId = json["req_id"] as? Int else { return }
        guard let state = pendingDownloads.removeValue(forKey: reqId) else { return }
        let serverOk = (json["success"] as? Bool) ?? false
        state.finish()
        if !state.background { foregroundCount -= 1 }
        // Promote partial → final destination only when the server confirms
        // success AND every expected byte arrived. The byte-count gate guards
        // against a stale partial being promoted after the remote file shrank
        // (resume offset > real size → server streams nothing). On failure the
        // .droidmate-partial is retained so the download can resume.
        let success = serverOk && state.received == state.totalBytes && state.promote()
        if let cont = pendingDownloadConts.removeValue(forKey: reqId) {
            cont.resume(returning: success)
        }
        if success {
            doneCount += 1
            doneBytes += state.totalBytes
            lastDoneName = state.entryName
            lastDoneURL = state.localURL
        }
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
        if pendingDownloads.isEmpty && pendingUploads.isEmpty {
            isTransferring = false
            recomputeProgress(force: true)
            if doneCount > 0 {
                lastCompletedTransfer = makeCompletedTransfer(direction: .download)
                sendCompletionNotification()
            }
        }
    }

    // MARK: - Progress

    private func recomputeProgress(force: Bool = false) {
        let total = pendingDownloads.values.reduce(Int64(0)) { $0 + $1.totalBytes } +
                    pendingUploads.values.reduce(Int64(0)) { $0 + $1.totalBytes }
        let done  = pendingDownloads.values.reduce(Int64(0)) { $0 + $1.received } +
                    pendingUploads.values.reduce(Int64(0)) { $0 + $1.sent }
        let p = total > 0 ? Double(done) / Double(total) : 0
        _transferProgress = p
        transferBytesDone = done
        transferBytesTotal = total

        let now = Date()
        let dt = now.timeIntervalSince(speedLastTime)
        if dt >= 0.3 {
            let db = Double(done - speedLastBytes)
            transferSpeedMBps = dt > 0 ? max(0, db / 1_000_000 / dt) : 0
            speedLastBytes = done
            speedLastTime = now
        }

        let big = abs(p - lastProgressEmit) >= 0.005
        let stale = now.timeIntervalSince(lastProgressEmitTime) >= 1.0/15
        guard force || big || stale else { return }
        lastProgressEmit = p
        lastProgressEmitTime = now

        let perSpeed = activeTransferCount > 0 && transferSpeedMBps > 0
            ? transferSpeedMBps / Double(activeTransferCount) : 0
        var items: [TransferItem] = []
        for (reqId, state) in pendingDownloads {
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
                direction: .upload, bytesDone: state.sent, bytesTotal: state.totalBytes, speedMBps: perSpeed
            ))
        }
        transfers = items
        objectWillChange.send()
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
    }

    private func sendCompletionNotification() {
        guard Bundle.main.bundleIdentifier != nil else { return }
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

struct DirEntry: Identifiable, Equatable, Hashable, Sendable {
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
}

struct TransferRecord: Identifiable, Equatable {
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
    enum Status { case completed, failed, cancelled }

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
    enum Direction { case download, upload }
    let name: String
    let bytes: Int64
    let direction: Direction
    let destinationURL: URL?
}

// MARK: - Transfer state (stream chunks to disk; multi-GB never in memory)

private final class DownloadState {
    let localURL: URL
    let partialURL: URL
    let entryName: String
    let entry: DirEntry
    let remotePath: String
    let background: Bool
    var totalBytes: Int64
    var received: Int64
    private let handle: FileHandle?

    init?(
        localURL: URL,
        partialURL: URL,
        entryName: String,
        entry: DirEntry,
        remotePath: String,
        totalBytes: Int64,
        startOffset: Int64,
        background: Bool
    ) {
        self.localURL = localURL
        self.partialURL = partialURL
        self.entryName = entryName
        self.entry = entry
        self.remotePath = remotePath
        self.background = background
        self.totalBytes = totalBytes
        self.received = startOffset
        if startOffset > 0 {
            // Resume: append to the existing partial.
            self.handle = try? FileHandle(forWritingTo: partialURL)
            _ = try? self.handle?.seekToEnd()
        } else {
            // Fresh: create/truncate the partial.
            FileManager.default.createFile(atPath: partialURL.path, contents: nil)
            self.handle = try? FileHandle(forWritingTo: partialURL)
        }
        if handle == nil { return nil }
    }

    func write(_ data: Data) {
        handle?.write(data)
        received += Int64(data.count)
    }

    func finish() {
        try? handle?.synchronize()
        try? handle?.close()
    }

    /// Promotes the partial to the final destination. Only call after the
    /// server confirms a complete transfer.
    func promote() -> Bool {
        guard handle != nil else { return false }
        do {
            if FileManager.default.fileExists(atPath: localURL.path) {
                try FileManager.default.removeItem(at: localURL)
            }
            try FileManager.default.moveItem(at: partialURL, to: localURL)
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
    init(totalBytes: Int64, sent: Int64, localURL: URL, destPath: String) {
        self.totalBytes = totalBytes
        self.sent = sent
        self.localURL = localURL
        self.destPath = destPath
    }
}
