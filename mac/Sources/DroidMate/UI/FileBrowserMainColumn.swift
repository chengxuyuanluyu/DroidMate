import SwiftUI
import UniformTypeIdentifiers

/// Browser content column for the session shell (path bar, list/grid, status).
/// Keeps file-list observation closer to `FileClient` so shell chrome (scrcpy
/// polling) does not re-measure the entire split from one mega-view body.
struct FileBrowserMainColumn: View {
    @ObservedObject var connMgr: ConnectionManager
    @ObservedObject var engine: DeviceSession
    @ObservedObject var client: FileClient
    @ObservedObject var scrcpy: ScrcpyController

    @Binding var selection: Set<DirEntry.ID>
    @Binding var renamingID: DirEntry.ID?
    @Binding var viewMode: ViewMode
    var searchFocused: FocusState<Bool>.Binding
    @Binding var dropTargeted: Bool
    @Binding var dropItemCount: Int?
    @Binding var showDeleteConfirm: Bool
    @Binding var showTransfers: Bool

    var reduceMotion: Bool

    var onDownload: (_ pickLocation: Bool) -> Void
    var onUpload: () -> Void
    var onDragOut: (DirEntry) -> NSItemProvider
    var onCopyPaths: () -> Void
    var onDrop: ([NSItemProvider]) -> Void

    @ObservedObject private var preview = PreviewController.shared

    private var selectionTotalSize: Int64 {
        selection.compactMap { client.visibleByID[$0]?.size }
            .reduce(Int64(0), +)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                FileBrowserPathBar(client: client, searchFocused: searchFocused)
                Divider()
                FileBrowserSessionBanner(engine: engine, connMgr: connMgr, scrcpy: scrcpy)
                FileBrowserLargeFolderHint(client: client) { searchFocused.wrappedValue = true }
                if client.isRecomputingVisible {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Sorting \(client.entries.count) items…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                }
                if let err = client.error {
                    ErrorBanner(message: err) {
                        withAnimation(DM.Motion.meso(reduceMotion: reduceMotion)) {
                            client.dismissError()
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                fileArea
                    .overlay(alignment: .top) {
                        if client.isNavigating {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Opening…")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.top, 10)
                            .transition(.opacity)
                        }
                    }
                    .animation(DM.Motion.micro(reduceMotion: reduceMotion), value: client.isNavigating)
                Divider()
                StatusBarView(
                    client: client,
                    transfers: client.transferEngine,
                    selectionCount: selection.count,
                    selectionTotalSize: selectionTotalSize,
                    onShowTransfers: { showTransfers = true }
                )
            }
            .background(Color(nsColor: .windowBackgroundColor))

            if dropTargeted {
                DropOverlayView(
                    isTargeted: true,
                    path: client.currentPath,
                    itemCount: dropItemCount
                )
                .transition(.opacity)
            }

            if preview.isPreparing {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Preparing preview…")
                        .font(.headline)
                    if let name = preview.preparingName {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .transition(.opacity)
            }
        }
        .onDrop(
            of: [UTType.fileURL],
            delegate: FileDropDelegate(
                isTargeted: $dropTargeted,
                itemCount: $dropItemCount,
                onDrop: { providers in onDrop(providers) }
            )
        )
    }

    // MARK: - File area

    @ViewBuilder
    private var fileArea: some View {
        if !engine.isSessionReady && client.entries.isEmpty {
            ContentUnavailableView {
                Label("Connecting…", systemImage: "iphone.gen3.radiowaves.left.and.right")
            } description: {
                Text("Setting up the data channel to your phone.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if client.isLoading && client.entries.isEmpty {
            LoadingSkeletonView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if client.visibleEntries.isEmpty && !client.searchQuery.isEmpty {
            ContentUnavailableView {
                Label("No results", systemImage: "magnifyingglass")
            } description: {
                Text("No items match \"\(client.searchQuery)\"")
            } actions: {
                Button("Clear Search") { client.searchQuery = "" }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if client.visibleEntries.isEmpty && client.filterType != .all && !client.entries.isEmpty {
            ContentUnavailableView {
                Label("No matching files", systemImage: filterSFSymbol(for: client.filterType))
            } description: {
                Text("Nothing matches the current filter in this folder.")
            } actions: {
                Button("Show All") { client.filterType = .all }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if client.entries.isEmpty && client.error == nil {
            emptyFolderPlaceholder
        } else {
            let openFolder: (DirEntry) -> Void = { entry in
                Task {
                    await client.list(path: client.child(of: client.currentPath, name: entry.name))
                }
            }
            let previewFile: (DirEntry) -> Void = { entry in
                Task { await PreviewController.shared.preview(entry: entry, using: client) }
            }
            let doCopy: () -> Void = {
                let names = selection.compactMap { client.visibleByID[$0]?.name }
                client.copySelected(names)
            }
            let doCut: () -> Void = {
                let names = selection.compactMap { client.visibleByID[$0]?.name }
                client.cutSelected(names)
            }
            let doPaste: () -> Void = {
                Task { await client.paste() }
            }
            let doDuplicate: () -> Void = {
                let names = selection.compactMap { client.visibleByID[$0]?.name }
                guard !names.isEmpty else { return }
                Task { await client.duplicate(names: names) }
            }
            switch viewMode {
            case .list:
                FileListView(
                    client: client,
                    selection: $selection,
                    renamingID: $renamingID,
                    onOpenFolder: openFolder,
                    onPreviewFile: previewFile,
                    onDownload: { onDownload(false) },
                    onDownloadTo: { onDownload(true) },
                    onDragOut: { entry in onDragOut(entry) },
                    onDelete: { if !selection.isEmpty { showDeleteConfirm = true } },
                    onRename: { entry in renamingID = entry.id },
                    onCommitRename: { entry, newName in
                        let trimmed = newName.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty, trimmed != entry.name, !trimmed.contains("/") {
                            Task { await client.rename(from: entry.name, to: trimmed) }
                        }
                        renamingID = nil
                    },
                    onCopy: doCopy, onCut: doCut, onPaste: doPaste,
                    onCopyPath: { onCopyPaths() },
                    onDuplicate: doDuplicate
                )
            case .grid:
                FileGridView(
                    client: client,
                    selection: $selection,
                    renamingID: $renamingID,
                    onOpenFolder: openFolder,
                    onPreviewFile: previewFile,
                    onDownload: { onDownload(false) },
                    onDownloadTo: { onDownload(true) },
                    onDragOut: { entry in onDragOut(entry) },
                    onDelete: { if !selection.isEmpty { showDeleteConfirm = true } },
                    onRename: { entry in renamingID = entry.id },
                    onCommitRename: { entry, newName in
                        let trimmed = newName.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty, trimmed != entry.name, !trimmed.contains("/") {
                            Task { await client.rename(from: entry.name, to: trimmed) }
                        }
                        renamingID = nil
                    },
                    onCopy: doCopy, onCut: doCut, onPaste: doPaste,
                    onCopyPath: { onCopyPaths() },
                    onDuplicate: doDuplicate
                )
            }
        }
    }

    private var emptyFolderPlaceholder: some View {
        VStack(spacing: DM.Space.lg) {
            ZStack {
                Circle()
                    .fill(DM.Brand.softFill)
                    .frame(width: 88, height: 88)
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(DM.Brand.iconOnDark)
                    .symbolRenderingMode(.hierarchical)
            }
            Text("Empty folder")
                .font(.title3.weight(.semibold))
            Text("Drag files here to upload, or use Upload in the toolbar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            HStack(spacing: DM.Space.sm) {
                Button {
                    onUpload()
                } label: {
                    Label("Upload…", systemImage: "arrow.up.doc")
                        .labelStyle(.titleAndIcon)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(client.isTransferring || !engine.isSessionReady)

                if client.canPaste {
                    Button {
                        Task { await client.paste() }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                            .labelStyle(.titleAndIcon)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DM.Space.xxl)
    }

    private func filterSFSymbol(for type: FileClient.FilterType) -> String {
        switch type {
        case .all: return "line.3.horizontal.decrease"
        case .images: return "photo"
        case .videos: return "film"
        case .audio: return "music.note"
        case .documents: return "doc.text"
        }
    }
}
