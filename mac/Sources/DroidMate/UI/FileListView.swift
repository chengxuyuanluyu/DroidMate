import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileContextMenu: View {
    let entry: DirEntry
    let selectionCount: Int
    let onOpenFolder: (DirEntry) -> Void
    let onPreviewFile: (DirEntry) -> Void
    let onDownload: () -> Void
    let onDownloadTo: () -> Void
    let onDelete: () -> Void
    let onRename: (DirEntry) -> Void
    let onRefresh: () async -> Void
    let onCopy: () -> Void
    let onCut: () -> Void
    let onPaste: () -> Void
    let onCopyPath: () -> Void
    var onDuplicate: (() -> Void)? = nil
    var canPaste: Bool = false

    var body: some View {
        if selectionCount > 1 {
            Button {
                onCopy()
            } label: {
                Label(String(localized: "Copy \(selectionCount) Items"), systemImage: "doc.on.doc")
            }
            Button {
                onCut()
            } label: {
                Label(String(localized: "Cut \(selectionCount) Items"), systemImage: "scissors")
            }
            if let onDuplicate {
                Button {
                    onDuplicate()
                } label: {
                    Label(String(localized: "Duplicate \(selectionCount) Items"), systemImage: "plus.square.on.square")
                }
            }
            Button {
                onDownload()
            } label: {
                Label(String(localized: "Download \(selectionCount) Items"), systemImage: "arrow.down.doc")
            }
            Button {
                onDownloadTo()
            } label: {
                Label("Download to…", systemImage: "folder.badge.plus")
            }
            Divider()
            Button {
                onCopyPath()
            } label: {
                Label("Copy Path", systemImage: "link")
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(String(localized: "Delete \(selectionCount) Items"), systemImage: "trash")
            }
        } else {
            if entry.isDir {
                Button {
                    onOpenFolder(entry)
                } label: {
                    Label("Open", systemImage: "folder")
                }
                Button {
                    onDownload()
                } label: {
                    Label("Download Folder", systemImage: "arrow.down.doc")
                }
                Button {
                    onDownloadTo()
                } label: {
                    Label("Download Folder to…", systemImage: "folder.badge.plus")
                }
            } else {
                Button {
                    onPreviewFile(entry)
                } label: {
                    Label("Preview", systemImage: "eye")
                }
                Button {
                    onDownload()
                } label: {
                    Label("Download", systemImage: "arrow.down.doc")
                }
                Button {
                    onDownloadTo()
                } label: {
                    Label("Download to…", systemImage: "folder.badge.plus")
                }
            }
            Divider()
            Button {
                onCopy()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                onCut()
            } label: {
                Label("Cut", systemImage: "scissors")
            }
            if let onDuplicate {
                Button {
                    onDuplicate()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
            }
            Button {
                onRename(entry)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                onCopyPath()
            } label: {
                Label("Copy Path", systemImage: "link")
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        Divider()
        Button {
            onPaste()
        } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
        }
        .disabled(!canPaste)
        Divider()
        Button {
            Task { await onRefresh() }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
    }
}

/// Finder-like file list backed by SwiftUI `List` **without** native
/// `selection:` — system selection paints solid blue + white text, which
/// clashes with the soft grid chrome. We own selection (⌘ / ⇧) and paint
/// the same `DMSelectionBackground` as the grid.
struct FileListView: View {
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

    /// Last row that received a mouse click — used so AppKit double-click opens
    /// the item under the pointer, not a stale multi-selection head.
    @State private var lastPointerId: DirEntry.ID?
    @State private var anchor: DirEntry.ID?
    @State private var typeaheadBuffer = ""
    @State private var typeaheadClearTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            columnHeader
            ScrollViewReader { proxy in
                List {
                    ForEach(client.visibleEntries) { entry in
                        let selected = selection.contains(entry.id)
                        FileRow(
                            entry: entry,
                            isSelected: selected,
                            isEditing: renamingID == entry.id,
                            onCommitRename: renamingID == entry.id ? { newName in
                                if let e = client.visibleByID[entry.id] {
                                    onCommitRename(e, newName)
                                }
                            } : nil
                        )
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 2, leading: DM.Space.sm, bottom: 2, trailing: DM.Space.sm))
                        .listRowBackground(
                            DMSelectionBackground(selected: selected, cornerRadius: DM.Radius.md)
                                .padding(.vertical, 1)
                        )
                        .id(entry.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            lastPointerId = entry.id
                            handleTap(entry)
                        }
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
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 30)
                .id(client.currentPath)
                .transaction { $0.animation = nil }
                .onChange(of: selection) { _, new in
                    if new.count == 1, let id = new.first {
                        lastPointerId = id
                        withAnimation(nil) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        // AppKit double-click (survives List row rebuild). Prefer pointer target.
        .onNativeDoubleClick {
            guard !client.isLoading else { return }
            openPointerOrSelection()
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1); return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1); return .handled
        }
        .onKeyPress(.return) {
            startRename(); return .handled
        }
        .onKeyPress(.space) {
            openAnchor(); return .handled
        }
        .onKeyPress(characters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")), phases: .down) { press in
            handleTypeahead(press.characters)
            return .handled
        }
        }
    }

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
        lastPointerId = entry.id
    }

    private func selectRange(from startID: DirEntry.ID, to endID: DirEntry.ID) {
        guard let start = client.visibleEntries.firstIndex(where: { $0.id == startID }),
              let end = client.visibleEntries.firstIndex(where: { $0.id == endID }) else { return }
        let lo = min(start, end), hi = max(start, end)
        selection = Set(client.visibleEntries[lo...hi].map(\.id))
    }

    private func handleTypeahead(_ chars: String) {
        guard let ch = chars.first else { return }
        if let id = TypeaheadJump.apply(
            character: ch,
            buffer: &typeaheadBuffer,
            entries: client.visibleEntries,
            currentSelection: selection,
            anchorID: lastPointerId ?? anchor
        ) {
            selection = [id]
            lastPointerId = id
            anchor = id
        }
        typeaheadClearTask?.cancel()
        typeaheadClearTask = Task {
            try? await Task.sleep(for: .seconds(TypeaheadJump.idleClearSeconds))
            guard !Task.isCancelled else { return }
            typeaheadBuffer = ""
        }
    }

    /// Double-click: open item under mouse if known, else current selection.
    private func openPointerOrSelection() {
        if let id = lastPointerId, let entry = client.visibleByID[id] {
            selection = [id]
            if entry.isDir { onOpenFolder(entry) }
            else { onPreviewFile(entry) }
            return
        }
        openAnchor()
    }

    // MARK: - Column header

    private var columnHeader: some View {
        HStack(spacing: DM.Space.sm) {
            // LocalizedStringKey literals — Text(String) is verbatim and skips zh-Hans.
            headerButton("Name", key: .name, alignment: .leading, width: nil)
            headerButton("Size", key: .size, alignment: .trailing, width: 64)
            headerButton("Date Modified", key: .modified, alignment: .trailing, width: 110)
        }
        .padding(.horizontal, DM.Space.md)
        .padding(.top, 5)
        .padding(.bottom, 5)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DM.cardStroke)
                .frame(height: 0.5)
        }
    }

    private func headerButton(_ title: LocalizedStringKey, key: FileClient.SortKey, alignment: Alignment, width: CGFloat?) -> some View {
        Button {
            client.toggleSort(key)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.caption.weight(.medium))
                if client.sortKey == key {
                    Image(systemName: client.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
            }
            .foregroundStyle(client.sortKey == key ? .primary : .secondary)
            .frame(maxWidth: width == nil ? .infinity : nil,
                   alignment: alignment)
            .frame(width: width)
        }
        .buttonStyle(.plain)
    }

    private func moveSelection(by delta: Int) {
        let entries = client.visibleEntries
        guard !entries.isEmpty else { return }
        let currentIdx = (lastPointerId ?? anchor ?? selection.first).flatMap { id in
            entries.firstIndex(where: { $0.id == id })
        } ?? (delta > 0 ? -1 : entries.count)
        let newIdx = (currentIdx + delta).clamped(to: 0...(entries.count - 1))
        selection = [entries[newIdx].id]
        lastPointerId = entries[newIdx].id
        anchor = entries[newIdx].id
    }

    private func openAnchor() {
        guard let id = selection.first,
              let entry = client.visibleEntries.first(where: { $0.id == id }) else { return }
        if entry.isDir { onOpenFolder(entry) } else { onPreviewFile(entry) }
    }

    private func startRename() {
        guard let id = selection.first,
              let entry = client.visibleByID[id] else { return }
        onRename(entry)
    }

}

// MARK: - Loading Skeleton

struct LoadingSkeletonView: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<10, id: \.self) { _ in
                ShimmerRow()
            }
            Spacer()
        }
    }
}

private struct ShimmerRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        rowShape
            .overlay(sweep)
            .mask(rowShape)
    }

    @ViewBuilder
    private var rowShape: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(.quaternary)
                .frame(width: 18, height: 18)
                .frame(width: 28)
            RoundedRectangle(cornerRadius: 3)
                .fill(.quaternary)
                .frame(height: 12)
                .frame(maxWidth: .infinity)
            RoundedRectangle(cornerRadius: 3)
                .fill(.quaternary)
                .frame(width: 64, height: 12)
            RoundedRectangle(cornerRadius: 3)
                .fill(.quaternary)
                .frame(width: 110, height: 12)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var sweep: some View {
        if !reduceMotion {
            GeometryReader { geo in
                LinearGradient(
                    colors: [.clear, .white.opacity(0.08), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geo.size.width * 0.4)
                .offset(x: geo.size.width * (phase - 0.4))
            }
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1.4
                }
            }
        }
    }
}

/// Pure row content. Interaction (select / open) lives on the parent List.
private struct FileRow: View {
    let entry: DirEntry
    var isSelected: Bool = false
    var isEditing: Bool = false
    var onCommitRename: ((String) -> Void)? = nil

    @State private var editBuffer: String = ""
    @State private var hovered = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let sizeWidth: CGFloat = 64
    private static let dateWidth: CGFloat = 110
    private static let iconWidth: CGFloat = 28

    var body: some View {
        HStack(spacing: DM.Space.sm) {
            icon
                .frame(width: 18, height: 18)
                .frame(width: Self.iconWidth)
            if isEditing {
                TextField("", text: $editBuffer)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onAppear {
                        editBuffer = entry.name
                        focused = true
                    }
                    .onSubmit {
                        onCommitRename?(editBuffer)
                    }
                    .onKeyPress(.escape) {
                        onCommitRename?(entry.name)
                        return .handled
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
            } else {
                Text(entry.name)
                    .font(.body.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
            }
            Text(entry.sizeText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Self.sizeWidth, alignment: .trailing)
            Text(entry.dateText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.dateWidth, alignment: .trailing)
        }
        .padding(.horizontal, DM.Space.xs)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Hover only here; selection fill is on listRowBackground (shared with grid).
        .background(
            RoundedRectangle(cornerRadius: DM.Radius.md, style: .continuous)
                .fill(!isSelected && hovered ? DM.subtleFill : Color.clear)
        )
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : AppSpring.crossfade, value: hovered)
        .animation(nil, value: isSelected)
        // Always primary text — never system “selected white on blue”.
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var icon: some View {
        if entry.isDir {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
        } else {
            Image(systemName: FileIconStyle.name(for: entry))
                .foregroundStyle(FileIconStyle.color(for: entry))
                .symbolRenderingMode(.hierarchical)
        }
    }
}
