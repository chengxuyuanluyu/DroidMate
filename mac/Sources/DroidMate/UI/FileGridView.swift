import SwiftUI
import UniformTypeIdentifiers

/// Toolbar view-mode toggle, persisted via `@AppStorage("ui.viewMode")`.
enum ViewMode: String, CaseIterable {
    case list
    case grid
}

/// Finder-style icon grid backed by `LazyVGrid`. Mirrors `FileListView`'s
/// selection semantics and closure set, but rolls its own selection state
/// machine — LazyVGrid has no native `selection:` binding the way List does.
///
/// Selection model (matches Finder):
///   - plain click: anchor = this; selection = {this}; open folder if dir
///   - ⌘-click: toggle in selection; anchor unchanged
///   - ⇧-click: range from anchor to this (inclusive)
///   - double-click: open folder / preview file
struct FileGridView: View {
    @ObservedObject var client: FileClient
    @Binding var selection: Set<DirEntry.ID>
    @Binding var renamingID: DirEntry.ID?
    let onOpenFolder: (DirEntry) -> Void
    let onPreviewFile: (DirEntry) -> Void
    let onDownload: () -> Void
    let onDownloadTo: () -> Void
    let onDragOut: (DirEntry) -> NSItemProvider?
    let onDelete: () -> Void
    let onRename: (DirEntry) -> Void
    let onCommitRename: (DirEntry, String) -> Void
    let onCopy: () -> Void
    let onCut: () -> Void
    let onPaste: () -> Void
    let onCopyPath: () -> Void
    var onDuplicate: (() -> Void)? = nil

    @State private var anchor: DirEntry.ID?
    @State private var lastPointerId: DirEntry.ID?
    @State private var typeaheadBuffer = ""
    @State private var typeaheadClearTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: DM.Space.sm) {
                ForEach(client.visibleEntries) { entry in
                    // Button is more reliable than onTapGesture + itemProvider:
                    // drag-out can swallow plain taps so selection never updates.
                    Button {
                        lastPointerId = entry.id
                        handleTap(entry)
                    } label: {
                        FileGridTile(
                            entry: entry,
                            isSelected: selection.contains(entry.id),
                            client: client,
                            isEditing: renamingID == entry.id,
                            onCommitRename: renamingID == entry.id ? { newName in
                                if let e = client.visibleByID[entry.id] {
                                    onCommitRename(e, newName)
                                }
                            } : nil
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .contextMenu {
                        FileContextMenu(
                            entry: entry, selectionCount: selection.count,
                            onOpenFolder: onOpenFolder, onPreviewFile: onPreviewFile,
                            onDownload: onDownload, onDownloadTo: onDownloadTo,
                            onDelete: onDelete, onRename: onRename,
                            onRefresh: { await client.refresh() },
                            onCopy: onCopy, onCut: onCut, onPaste: onPaste,
                            onCopyPath: onCopyPath, onDuplicate: onDuplicate,
                            canPaste: client.canPaste
                        )
                    }
                    .itemProvider {
                        onDragOut(entry)
                    }
                }
            }
            .padding(DM.Space.md)
        }
        .id(client.currentPath)
        .transaction { $0.animation = nil }
        // AppKit double-click opens the tile under the pointer (folder / preview).
        .onNativeDoubleClick {
            guard !client.isLoading else { return }
            if let id = lastPointerId, let entry = client.visibleByID[id] {
                selection = [id]
                anchor = id
                if entry.isDir { onOpenFolder(entry) }
                else { onPreviewFile(entry) }
            } else {
                openAnchor()
            }
        }
        .onKeyPress(.upArrow) { moveSelectionGrid(by: -columnsCount); return .handled }
        .onKeyPress(.downArrow) { moveSelectionGrid(by: columnsCount); return .handled }
        .onKeyPress(.leftArrow) { moveSelectionGrid(by: -1); return .handled }
        .onKeyPress(.rightArrow) { moveSelectionGrid(by: 1); return .handled }
        .onKeyPress(.return) { startRename(); return .handled }
        .onKeyPress(.space)   { openAnchor(); return .handled }
        .onKeyPress(characters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")), phases: .down) { press in
            handleTypeahead(press.characters)
            return .handled
        }
    }

    private func handleTypeahead(_ chars: String) {
        guard let ch = chars.first else { return }
        if let id = TypeaheadJump.apply(
            character: ch,
            buffer: &typeaheadBuffer,
            entries: client.visibleEntries,
            currentSelection: selection
        ) {
            selection = [id]
            anchor = id
            lastPointerId = id
        }
        typeaheadClearTask?.cancel()
        typeaheadClearTask = Task {
            try? await Task.sleep(for: .seconds(TypeaheadJump.idleClearSeconds))
            guard !Task.isCancelled else { return }
            typeaheadBuffer = ""
        }
    }

    /// Approximate number of columns based on the grid width and tile minimum.
    private var columnsCount: Int {
        max(1, Int(800 / 128))
    }

    private func moveSelectionGrid(by delta: Int) {
        let entries = client.visibleEntries
        guard !entries.isEmpty else { return }
        let currentIdx = selection.first.flatMap { id in
            entries.firstIndex(where: { $0.id == id })
        } ?? (delta > 0 ? -1 : entries.count)
        let newIdx = (currentIdx + delta).clamped(to: 0...(entries.count - 1))
        selection = [entries[newIdx].id]
        anchor = entries[newIdx].id
    }

    // MARK: - Selection

    private func handleTap(_ entry: DirEntry) {
        let mods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.shift), let a = anchor {
            selectRange(from: a, to: entry.id)
        } else if mods.contains(.command) {
            if selection.contains(entry.id) { selection.remove(entry.id) }
            else { selection.insert(entry.id) }
            if anchor == nil { anchor = entry.id }
        } else {
            selection = [entry.id]
            anchor = entry.id
        }
    }

    private func selectRange(from startID: DirEntry.ID, to endID: DirEntry.ID) {
        guard let start = client.visibleEntries.firstIndex(where: { $0.id == startID }),
              let end = client.visibleEntries.firstIndex(where: { $0.id == endID }) else { return }
        let lo = min(start, end), hi = max(start, end)
        selection = Set(client.visibleEntries[lo...hi].map(\.id))
    }

    private func openAnchor() {
        guard let id = selection.first,
              let entry = client.visibleByID[id] else { return }
        if entry.isDir { onOpenFolder(entry) } else { onPreviewFile(entry) }
    }

    private func startRename() {
        guard let id = selection.first, let entry = client.visibleByID[id] else { return }
        onRename(entry)
    }
}

// MARK: - Tile

/// Dumb value-type tile. Owns its thumbnail state so parent rebuilds
/// (selection changes, list refreshes) don't re-trigger downloads for the
/// currently-visible tiles.
private struct FileGridTile: View {
    let entry: DirEntry
    let isSelected: Bool
    let client: FileClient
    var isEditing: Bool = false
    var onCommitRename: ((String) -> Void)? = nil

    @State private var thumbnail: NSImage?
    @State private var editBuffer: String = ""
    @FocusState private var focused: Bool

    private static let thumbHeight: CGFloat = 84
    @State private var hovered = false

    var body: some View {
        VStack(spacing: DM.Space.xs) {
            preview
                .frame(height: Self.thumbHeight)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: DM.Radius.sm, style: .continuous)
                        .fill(DM.panelFill)
                )
                .clipShape(RoundedRectangle(cornerRadius: DM.Radius.sm, style: .continuous))
            if isEditing {
                TextField("", text: $editBuffer)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .focused($focused)
                    .onAppear {
                        editBuffer = entry.name
                        focused = true
                    }
                    .onSubmit { onCommitRename?(editBuffer) }
                    .onKeyPress(.escape) {
                        onCommitRename?(entry.name)
                        return .handled
                    }
            } else {
                Text(entry.name)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .top)
                    .foregroundStyle(.primary)
            }
        }
        .padding(DM.Space.sm)
        .frame(minWidth: 0)
        .background(
            RoundedRectangle(cornerRadius: DM.Radius.md, style: .continuous)
                .fill(isSelected
                      ? DM.selectionFill(active: true)
                      : (hovered ? DM.subtleFill : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DM.Radius.md, style: .continuous)
                .strokeBorder(
                    isSelected ? DM.selectionStroke(active: true) : (hovered ? DM.cardStroke : Color.clear),
                    lineWidth: isSelected ? 1.25 : 0.5
                )
        )
        .onHover { hovered = $0 }
        // Hover can ease; selection must paint on the same frame as the click.
        .animation(AppSpring.crossfade, value: hovered)
        .animation(nil, value: isSelected)
        .onAppear { tryFetchThumbnail() }
        .onChange(of: entry.id) {
            thumbnail = nil
            tryFetchThumbnail()
        }
    }

    @ViewBuilder
    private var preview: some View {
        if entry.isDir {
            Image(systemName: "folder.fill")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let thumbnail, isMedia {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            Image(systemName: FileIconStyle.name(for: entry))
                .font(.system(size: 38))
                .foregroundStyle(FileIconStyle.color(for: entry))
                .symbolRenderingMode(.hierarchical)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var isMedia: Bool {
        entry.mime.hasPrefix("image/") || entry.mime.hasPrefix("video/")
    }

    private func tryFetchThumbnail() {
        guard thumbnail == nil else { return }
        // Huge folders: skip eager thumbs; user can open inspector / preview instead.
        if client.entries.count >= FileClient.largeFolderThreshold { return }
        // Don't fight user transfers for bandwidth.
        if client.hasForegroundTransfer { return }
        Task {
            if let img = await ThumbnailCache.shared.getThumbnail(for: entry, client: client) {
                thumbnail = img
            }
        }
    }
}
