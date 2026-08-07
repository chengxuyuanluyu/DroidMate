import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Right-hand inspector panel for the selected file/folder.
///
/// Shows:
///   - File info (name, size, modified, path, type) for everything.
///   - Image thumbnail for images ≤ 5 MB (auto-downloaded on select).
///   - Type icon + "double-click to preview" for everything else.
///
/// Designed to be cheap: the info section is pure local data (zero network).
/// Only single-image auto-download fires, and only for small images — large
/// files and non-images require an explicit double-click → QuickLook.
struct FileInspectorView: View {
    let entry: DirEntry?
    let currentPath: String
    let client: FileClient
    /// Quick actions from the parent browser (download / open / preview).
    var onOpen: (() -> Void)? = nil
    var onDownload: (() -> Void)? = nil
    var onDownloadTo: (() -> Void)? = nil
    var onDuplicate: (() -> Void)? = nil

    /// Auto-downloaded thumbnail for small images. Persists across re-selects
    /// of the same file to avoid re-downloading.
    @State private var thumbnail: NSImage?
    @State private var isFetchingThumbnail = false
    @State private var folderItemCount: Int?
    @State private var folderSizeText: String?
    @State private var folderSizeTask: Task<Void, Never>?

    var body: some View {
        // Identity by selection id so list-driven parent rebuilds don't
        // re-init inspector chrome unless the selected entry changed.
        Group {
            if let entry {
                GeometryReader { geo in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            previewSection(for: entry)
                            actionSection(for: entry)
                            infoSection(for: entry)
                        }
                        .padding(16)
                        // Lock the content width to the column width instead of
                        // the scroll view's proposal: on macOS a (legacy) scroll
                        // bar appearing/disappearing shrinks the proposal by ~15pt,
                        // which would reflow every maxWidth: .infinity element
                        // ("layout zooms when the scroll bar shows"). Reserve the
                        // scroller gutter so the width never changes.
                        .frame(width: max(0, geo.size.width - 15), alignment: .leading)
                    }
                    .id(entry.id)
                }
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "doc",
                    description: Text("Select a file to see details")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(DM.Motion.selection, value: entry?.id)
        // Re-fetch thumbnail when the selected entry changes.
        .onChange(of: entry?.id) {
            thumbnail = nil
            isFetchingThumbnail = false
            folderItemCount = nil
            folderSizeText = nil
            tryFetchThumbnail(for: entry)
            tryFetchFolderCount(for: entry)
            tryFetchFolderSize(for: entry)
        }
        .onAppear {
            tryFetchThumbnail(for: entry)
            tryFetchFolderCount(for: entry)
            tryFetchFolderSize(for: entry)
        }
    }

    // MARK: - Quick actions

    @ViewBuilder
    private func actionSection(for entry: DirEntry) -> some View {
        VStack(spacing: 6) {
            if entry.isDir {
                if let onOpen {
                    Button {
                        onOpen()
                    } label: {
                        Label("Open Folder", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                if let onDownload {
                    Button {
                        onDownload()
                    } label: {
                        Label("Download Folder", systemImage: "arrow.down.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(client.isTransferring)
                }
            } else {
                if let onOpen {
                    Button {
                        onOpen()
                    } label: {
                        Label("Preview", systemImage: "eye")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                if let onDownload {
                    Button {
                        onDownload()
                    } label: {
                        Label("Download", systemImage: "arrow.down.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(client.isTransferring)
                }
                if let onDownloadTo {
                    Button {
                        onDownloadTo()
                    } label: {
                        Label("Download to…", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(client.isTransferring)
                }
            }
            if let onDuplicate {
                Button {
                    onDuplicate()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(client.isTransferring)
            }
            Button {
                let path = fullPath(for: entry)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(path, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(fullPath(for: entry))
        }
    }

    // MARK: - Preview

    /// Fixed stage height for the thumbnail/spinner states so swapping between
    /// them never changes the content height (see body: scroll-bar flapping).
    private let previewStageHeight: CGFloat = 240

    @ViewBuilder
    private func previewSection(for entry: DirEntry) -> some View {
        if entry.isDir {
            VStack(spacing: DM.Space.sm) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                Text("Folder")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DM.Space.xl)
            .background(
                RoundedRectangle(cornerRadius: DM.Radius.lg, style: .continuous)
                    .fill(DM.Brand.softFill)
            )
        } else if let thumbnail, isMedia(entry) {
            // Fixed-height stage: the thumbnail replaces the spinner at the
            // same height, so the content height (and the scroll bar) doesn't
            // flap while a thumbnail loads.
            ZStack {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: previewStageHeight)
                    .clipShape(RoundedRectangle(cornerRadius: DM.Radius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DM.Radius.md, style: .continuous)
                            .strokeBorder(DM.cardStroke, lineWidth: 0.5)
                    )
            }
            .frame(maxWidth: .infinity)
            .frame(height: previewStageHeight)
        } else if isFetchingThumbnail {
            ZStack {
                ProgressView()
                    .controlSize(.regular)
            }
            .frame(maxWidth: .infinity)
            .frame(height: previewStageHeight)
        } else {
            VStack(spacing: DM.Space.sm) {
                Image(systemName: FileIconStyle.name(for: entry))
                    .font(.system(size: 48))
                    .foregroundStyle(FileIconStyle.color(for: entry))
                    .symbolRenderingMode(.hierarchical)
                if !entry.isDir {
                    Text("Double-click to preview")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DM.Space.xl)
            .background(
                RoundedRectangle(cornerRadius: DM.Radius.lg, style: .continuous)
                    .fill(DM.panelFill)
            )
        }
    }

    // MARK: - Info

    private func infoSection(for entry: DirEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if entry.isDir {
                if let count = folderItemCount {
                    infoRow("Items", "\(count)")
                } else {
                    infoRow("Items", "—")
                }
                if let size = folderSizeText {
                    infoRow("Size", size)
                } else {
                    infoRow("Size", "—")
                }
            } else {
                infoRow("Size", entry.sizeText)
            }
            infoRow("Modified", entry.dateText)
            infoRow("Type", entry.mime)
            infoRow("Path", fullPath(for: entry))
        }
    }

    private func infoRow(_ key: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // LocalizedStringKey so labels (Size/Modified/…) look up Localizable.strings.
            // Text(String) is verbatim and never localizes.
            Text(key)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            // Values are data (path, size, mime) — keep as-is.
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    // MARK: - Thumbnail fetch

    private func tryFetchThumbnail(for entry: DirEntry?) {
        guard let entry, !entry.isDir,
              thumbnail == nil,
              !isFetchingThumbnail else { return }
        // Large images skip the auto-download: pulling a multi-MB original just
        // to render a 512px thumbnail wastes bandwidth — double-click previews
        // them via QuickLook instead.
        if entry.mime.hasPrefix("image/") && entry.size > 5_000_000 { return }
        isFetchingThumbnail = true
        let token = entry.id
        Task {
            if let img = await ThumbnailCache.shared.getThumbnail(for: entry, client: client) {
                // Discard if the user selected a different entry while we fetched.
                guard token == self.entry?.id else { return }
                thumbnail = img
            }
            isFetchingThumbnail = false
        }
    }

    /// Lazily lists a folder's contents to show an item count in the inspector.
    /// Only fires for directories. Captures the entry id so a stale listDir
    /// (from a previously-selected folder arriving late) is discarded.
    private func tryFetchFolderCount(for entry: DirEntry?) {
        guard let entry, entry.isDir, folderItemCount == nil else { return }
        let path = client.child(of: currentPath, name: entry.name)
        let token = entry.id
        Task {
            let listed = await client.transferEngine.listDir(path: path)
            // Discard if the user selected a different entry while we fetched.
            guard token == self.entry?.id else { return }
            folderItemCount = listed.entries.count
        }
    }

    /// Lazily computes a folder's total size (recursive, cached in FileClient).
    /// The walk is cancelled when the selection changes so it stops issuing
    /// transport requests after the user navigates away.
    private func tryFetchFolderSize(for entry: DirEntry?) {
        guard let entry, entry.isDir, folderSizeText == nil else { return }
        let path = client.child(of: currentPath, name: entry.name)
        let token = entry.id
        folderSizeTask?.cancel()
        folderSizeTask = Task {
            let bytes = await client.folderSize(path: path)
            // Discard if the user selected a different entry while we fetched.
            guard token == self.entry?.id else { return }
            folderSizeText = bytes.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            }
        }
    }

    private func isMedia(_ entry: DirEntry) -> Bool {
        entry.mime.hasPrefix("image/") || entry.mime.hasPrefix("video/")
    }

    // MARK: - Path helper

    private func fullPath(for entry: DirEntry) -> String {
        client.absoluteDevicePath(relative: client.child(of: currentPath, name: entry.name))
    }
}
