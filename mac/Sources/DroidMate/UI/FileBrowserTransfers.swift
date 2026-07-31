import AppKit
import Foundation
import UniformTypeIdentifiers

/// Download / upload / drag-out helpers used by `FileBrowserView`.
/// Kept out of the view so the browser shell stays scannable.
@MainActor
enum FileBrowserTransfers {

    /// UserDefaults: open Transfer Queue when starting 2+ file operations.
    static var autoShowQueueEnabled: Bool {
        UserDefaults.standard.object(forKey: "transfer.auto_show_queue") as? Bool ?? true
    }

    static func maybeOpenQueue(itemCount: Int) {
        guard autoShowQueueEnabled, itemCount >= 2 else { return }
        NotificationCenter.default.post(name: .openTransfers, object: nil)
    }

    /// Prefer last chosen folder, else the user's Downloads directory.
    static var defaultDownloadDirectory: URL {
        if let last = UserDefaults.standard.string(forKey: "lastDownloadDir") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: last, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: last, isDirectory: true)
            }
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// - Parameter pickLocation: `true` shows a save/folder panel.
    static func downloadSelection(
        client: FileClient,
        selection: Set<DirEntry.ID>,
        pickLocation: Bool
    ) {
        let items = client.visibleEntries.filter { selection.contains($0.id) }
        guard !items.isEmpty else { return }
        let files = items.filter { !$0.isDir }
        let dirs = items.filter(\.isDir)

        if pickLocation {
            if files.count == 1, dirs.isEmpty, let file = files.first {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = file.name
                panel.directoryURL = defaultDownloadDirectory
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let url = panel.url else { return }
                UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "lastDownloadDir")
                Task { await client.download(entry: file, to: url) }
                return
            }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.prompt = String(localized: "Download Here")
            panel.directoryURL = defaultDownloadDirectory
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            UserDefaults.standard.set(dir.path, forKey: "lastDownloadDir")
            downloadItems(client: client, files: files, dirs: dirs, to: dir)
            return
        }

        let dir = defaultDownloadDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        downloadItems(client: client, files: files, dirs: dirs, to: dir)
    }

    static func downloadItems(
        client: FileClient,
        files: [DirEntry],
        dirs: [DirEntry],
        to dir: URL
    ) {
        var existing = NameConflict.existingNames(in: dir)
        let all = files + dirs
        let conflictNames = all.map(\.name).filter { existing.contains($0) }
        var rename: [String: String] = [:]
        if !conflictNames.isEmpty {
            let label = conflictNames.count == 1 ? conflictNames[0] : "\(conflictNames.count) items"
            switch NameConflict.choose(for: label) {
            case .cancel: return
            case .replace: break
            case .keepBoth:
                for name in conflictNames {
                    let unique = NameConflict.uniqueName(name, among: existing)
                    rename[name] = unique
                    existing.insert(unique)
                }
            }
        }
        let batchCount = files.count + dirs.count
        maybeOpenQueue(itemCount: batchCount)
        Task {
            for folder in dirs {
                let remote = client.child(of: client.currentPath, name: folder.name)
                let localName = rename[folder.name] ?? folder.name
                let dest = dir.appendingPathComponent(localName)
                _ = await client.downloadDirectory(remotePath: remote, to: dest)
            }
            struct Job: Sendable {
                let entry: DirEntry
                let dest: URL
            }
            let jobs: [Job] = files.map { file in
                let localName = rename[file.name] ?? file.name
                return Job(entry: file, dest: dir.appendingPathComponent(localName))
            }
            _ = await TransferEngine.runBounded(jobs) { job in
                await client.downloadAndWait(entry: job.entry, to: job.dest)
            }
        }
    }

    static func uploadWithOpenPanel(client: FileClient) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        guard let plan = resolveUploadConflicts(client: client, urls: panel.urls) else { return }
        maybeOpenQueue(itemCount: plan.urls.count)
        Task {
            await client.uploadMany(plan.urls, renameMap: plan.renameMap)
        }
    }

    static func handleDrop(client: FileClient, providers: [NSItemProvider]) {
        let box = DropURLBox()
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                box.append(url)
            }
        }
        group.notify(queue: .main) {
            let urls = box.urls
            Task { @MainActor in
                guard let plan = resolveUploadConflicts(client: client, urls: urls) else { return }
                maybeOpenQueue(itemCount: plan.urls.count)
                await client.uploadMany(plan.urls, renameMap: plan.renameMap)
            }
        }
    }

    /// Returns nil if the user cancelled. `renameMap` only set for Keep Both.
    static func resolveUploadConflicts(
        client: FileClient,
        urls: [URL]
    ) -> (urls: [URL], renameMap: [String: String])? {
        guard !urls.isEmpty else { return nil }
        let existing = Set(client.entries.map(\.name))
        let conflictNames = urls.map(\.lastPathComponent).filter { existing.contains($0) }
        guard !conflictNames.isEmpty else {
            return (urls, [:])
        }
        let label = conflictNames.count == 1 ? conflictNames[0] : "\(conflictNames.count) items"
        switch NameConflict.choose(for: label) {
        case .cancel:
            return nil
        case .replace:
            return (urls, [:])
        case .keepBoth:
            var map: [String: String] = [:]
            var used = existing
            for name in Set(conflictNames) {
                let unique = NameConflict.uniqueName(name, among: used)
                map[name] = unique
                used.insert(unique)
            }
            return (urls, map)
        }
    }

    /// Drag to Finder. Multi-select: if the dragged row is part of a larger
    /// selection, pull every selected item into a temp folder and drag that.
    static func dragOutProvider(
        client: FileClient,
        entry: DirEntry,
        selection: Set<DirEntry.ID>
    ) -> NSItemProvider {
        let dragEntries: [DirEntry] = {
            if selection.count > 1, selection.contains(entry.id) {
                return client.visibleEntries.filter { selection.contains($0.id) }
            }
            return [entry]
        }()
        let currentPath = client.currentPath
        let multi = dragEntries.count > 1

        let provider = NSItemProvider()
        provider.suggestedName = multi
            ? String(localized: "\(dragEntries.count) items")
            : dragEntries[0].name

        let totalBytes = dragEntries.reduce(Int64(0)) { sum, e in
            sum + (e.isDir ? 1 : max(e.size, 1))
        }
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.data.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: max(totalBytes, 1))
            Task { @MainActor in
                let baseDir = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("DroidMateDrag", isDirectory: true)
                try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
                let sessionDir = baseDir.appendingPathComponent(UUID().uuidString)
                try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

                var anyOK = false
                for item in dragEntries {
                    let dest = sessionDir.appendingPathComponent(item.name)
                    let ok: Bool
                    if item.isDir {
                        let remotePath = client.child(of: currentPath, name: item.name)
                        ok = await client.downloadDirectory(remotePath: remotePath, to: dest)
                    } else {
                        ok = await client.downloadAndWait(entry: item, to: dest)
                    }
                    if ok { anyOK = true }
                }

                let dropURL: URL?
                if !anyOK {
                    dropURL = nil
                } else if multi {
                    dropURL = sessionDir
                } else {
                    dropURL = sessionDir.appendingPathComponent(dragEntries[0].name)
                }
                completion(dropURL, false, nil)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(300))
                    try? FileManager.default.removeItem(at: sessionDir)
                }
            }
            return progress
        }
        return provider
    }
}
