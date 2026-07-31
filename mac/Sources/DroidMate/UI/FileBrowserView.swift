import SwiftUI
import UniformTypeIdentifiers

/// Connected screen: a Finder-native NavigationSplitView over the Android
/// filesystem. Sidebar lists device + locations; content shows toolbar,
/// breadcrumb, table, status bar. Drag-in upload targets the content area.
struct FileBrowserView: View {
    @ObservedObject var connMgr: ConnectionManager
    @ObservedObject var engine: DeviceSession
    @ObservedObject var client: FileClient
    var serial: String?
    @ObservedObject var scrcpy: ScrcpyController

    @State private var selection: Set<DirEntry.ID> = []
    @State private var dropTargeted = false
    @State private var dropItemCount: Int?
    @State private var showTransfers = false
    @State private var showAppManager = false
    @AppStorage("ui.viewMode") private var viewMode: ViewMode = .list

    @State private var showDeleteConfirm = false
    @State private var showNewFolder = false
    @State private var newFolderText = ""
    @State private var showGoToPath = false
    @State private var goToPathText = ""
    /// Entry currently being renamed inline. When set, the row swaps its name
    /// label for a focused TextField. nil = no inline edit active.
    @State private var renamingID: DirEntry.ID?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            SidebarView(connMgr: connMgr, engine: engine, client: client, serial: serial, scrcpy: scrcpy)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(min: 400, ideal: 500)
        } detail: {
            FileInspectorView(
                entry: selectedEntry,
                currentPath: client.currentPath,
                client: client,
                onOpen: { openSelected() },
                onDownload: { downloadSelection(pickLocation: false) },
                onDownloadTo: { downloadSelection(pickLocation: true) },
                onDuplicate: {
                    let names = selection.compactMap { client.visibleByID[$0]?.name }
                    guard !names.isEmpty else { return }
                    Task { await client.duplicate(names: names) }
                }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("DroidMate")
        .navigationSubtitle(pathSubtitle)
        .toolbar {
            FileBrowserToolbar(
                client: client,
                engine: engine,
                scrcpy: scrcpy,
                viewMode: $viewMode,
                showNewFolder: $showNewFolder,
                newFolderText: $newFolderText,
                showTransfers: $showTransfers,
                showAppManager: $showAppManager,
                selectionContainsDownloadable: selectionContainsDownloadable,
                onDownload: { downloadSelection(pickLocation: $0) },
                onUpload: { uploadFile() },
                onInstallApk: { installApk() }
            )
        }
        // Must key by device serial: without an id this task runs only once for
        // the whole FileBrowserView lifetime. Switching to a second device would
        // leave that device's FileClient empty forever (never listDir'd).
        .task(id: engine.deviceSerial) {
            // Resume last folder once the session is ready (not while handshaking).
            guard engine.isSessionReady else { return }
            if client.entries.isEmpty {
                await listRestoredOrRoot()
            }
        }
        // First ready after connect / reconnect: list or refresh.
        .onChange(of: engine.transportState) { old, new in
            guard new == .ready, old != .ready else { return }
            Task {
                if client.entries.isEmpty {
                    await listRestoredOrRoot()
                } else {
                    await client.refresh()
                }
            }
        }
        // Clear selection when navigating so inspector doesn't show a stale entry id.
        .onChange(of: client.currentPath) { _, _ in
            selection = []
            renamingID = nil
        }
        .sheet(isPresented: $showTransfers) {
            TransferQueueView(client: client, transfers: client.transferEngine)
        }
        .sheet(isPresented: $showAppManager) {
            AppManagerView(serial: engine.deviceSerial)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAppManager)) { _ in
            showAppManager = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .newFolder)) { _ in
            newFolderText = ""
            showNewFolder = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openTransfers)) { _ in
            showTransfers = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleViewMode)) { _ in
            viewMode = viewMode == .list ? .grid : .list
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let names = selection.compactMap { client.visibleByID[$0]?.name }
                Task { await client.delete(names: names) }
                selection = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderText)
            Button("Create") {
                let name = newFolderText.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty && !name.contains("/") {
                    Task { await client.makeDirectory(name: name) }
                }
                newFolderText = ""
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Go to Path", isPresented: $showGoToPath) {
            TextField("Android path (e.g. /sdcard/Download)", text: $goToPathText)
            Button("Go") {
                let path = goToPathText
                goToPathText = ""
                Task { await client.jumpToPath(path) }
            }
            Button("Cancel", role: .cancel) { goToPathText = "" }
        } message: {
            Text("Enter an absolute path on the phone, or a shortcut like Download or DCIM.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .showGoToPath)) { _ in
            goToPathText = client.currentPath
            showGoToPath = true
        }
        .alert(
            "Cannot start mirror",
            isPresented: showScrcpyErrorBinding
        ) {
            Button("Recheck scrcpy") {
                scrcpy.refreshAvailability()
                if scrcpy.isAvailable {
                    scrcpy.clearLaunchError()
                }
            }
            Button("OK", role: .cancel) {
                scrcpy.clearLaunchError()
            }
        } message: {
            Text(scrcpy.launchError ?? "")
        }
        .background {
            Group {
                Button("Select All") { selection = Set(client.visibleEntries.map(\.id)) }
                    .keyboardShortcut("a", modifiers: .command)
                Button("Deselect All") { selection.removeAll() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Go Up") { Task { await client.goUp() } }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Open") { openSelected() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(selection.isEmpty)
                Button("Back") { Task { await client.goBack() } }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward") { Task { await client.goForward() } }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Go to Path…") {
                    goToPathText = client.currentPath
                    showGoToPath = true
                }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Copy") {
                    let names = selection.compactMap { client.visibleByID[$0]?.name }
                    client.copySelected(names)
                }
                    .keyboardShortcut("c", modifiers: .command)
                    .disabled(selection.isEmpty)
                Button("Cut") {
                    let names = selection.compactMap { client.visibleByID[$0]?.name }
                    client.cutSelected(names)
                }
                    .keyboardShortcut("x", modifiers: .command)
                    .disabled(selection.isEmpty)
                Button("Paste") {
                    Task { await client.paste() }
                }
                    .keyboardShortcut("v", modifiers: .command)
                    .disabled(!client.canPaste)
                Button("Copy Path") { copySelectedPaths() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Delete") {
                    if !selection.isEmpty { showDeleteConfirm = true }
                }
                    .keyboardShortcut(.delete, modifiers: .command)
                Button("Download") {
                    downloadSelection(pickLocation: false)
                }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(client.isTransferring || !selectionContainsDownloadable)
                Button("Download to…") {
                    downloadSelection(pickLocation: true)
                }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(client.isTransferring || !selectionContainsDownloadable)
                Button("Find") {
                    searchFocused = true
                }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Refresh") {
                    Task { await client.refresh() }
                }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(client.isTransferring)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        }
    }

    /// Single selected entry for the inspector panel.
    /// O(1) via `client.visibleByID`; was O(n) linear scan on every body re-eval.
    private var selectedEntry: DirEntry? {
        guard selection.count == 1,
              let id = selection.first else { return nil }
        return client.visibleByID[id]
    }

    private var deleteDialogTitle: String {
        if selection.count > 1 {
            return String(localized: "Delete \(selection.count) items?")
        }
        let name = selectedEntry?.name ?? ""
        return String(localized: "Delete \"\(name)\"?")
    }

    private var showScrcpyErrorBinding: Binding<Bool> {
        Binding(
            get: { scrcpy.launchError != nil },
            set: { if !$0 { scrcpy.clearLaunchError() } }
        )
    }

    /// ⌘O — open selected folder or preview selected file (Finder-style).
    private func openSelected() {
        guard let entry = selectedEntry else { return }
        if entry.isDir {
            Task {
                await client.list(path: client.child(of: client.currentPath, name: entry.name))
            }
        } else {
            Task { await PreviewController.shared.preview(entry: entry, using: client) }
        }
    }

    /// Last-path restore may point at a deleted folder — fall back to storage root.
    private func listRestoredOrRoot() async {
        client.restoreLastPath()
        let ok = await client.list(path: client.currentPath)
        if !ok, client.currentPath != "/" {
            await client.list(path: "/")
        }
    }

    // MARK: - Content column

    private var contentColumn: some View {
        ZStack {
            VStack(spacing: 0) {
                FileBrowserPathBar(client: client, searchFocused: $searchFocused)
                Divider()
                FileBrowserSessionBanner(engine: engine, connMgr: connMgr, scrcpy: scrcpy)
                FileBrowserLargeFolderHint(client: client) { searchFocused = true }
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
                        withAnimation(AppSpring.standard) { client.dismissError() }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                fileArea
                    .opacity(client.isNavigating ? 0.55 : 1)
                    .animation(AppSpring.crossfade, value: client.isNavigating)
                    .overlay(alignment: .top) {
                        if client.isNavigating {
                            ProgressView()
                                .controlSize(.small)
                                .padding(8)
                                .background(.regularMaterial, in: Capsule())
                                .padding(.top, 10)
                                .transition(.opacity)
                        }
                    }
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
            if PreviewController.shared.isPreparing {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Preparing preview…")
                        .font(.headline)
                    if let name = PreviewController.shared.preparingName {
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
                onDrop: { providers in handleDrop(providers: providers) }
            )
        )
        .animation(AppSpring.standard, value: engine.transportState)
        .animation(AppSpring.standard, value: engine.recoveryPhase)
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
                Label("No matching files", systemImage: Self.filterSFSymbol(for: client.filterType))
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
                    onDownload: { downloadSelection(pickLocation: false) },
                    onDownloadTo: { downloadSelection(pickLocation: true) },
                    onDragOut: { entry in dragOutProvider(for: entry) },
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
                    onCopyPath: { copySelectedPaths() },
                    onDuplicate: doDuplicate
                )
            case .grid:
                FileGridView(
                    client: client,
                    selection: $selection,
                    renamingID: $renamingID,
                    onOpenFolder: openFolder,
                    onPreviewFile: previewFile,
                    onDownload: { downloadSelection(pickLocation: false) },
                    onDownloadTo: { downloadSelection(pickLocation: true) },
                    onDragOut: { entry in dragOutProvider(for: entry) },
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
                    onCopyPath: { copySelectedPaths() },
                    onDuplicate: doDuplicate
                )
            }
        }
    }

    /// Empty directory: nudge toward the primary upload path (drag or toolbar).
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
                    uploadFile()
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
    private var pathSubtitle: String {
        // Device model is already shown in the sidebar header — don't repeat
        // it here. Show only the current folder name so subtitle never truncates.
        guard client.currentPath != "/" else { return "" }
        return client.currentPath.split(separator: "/").last.map(String.init) ?? ""
    }

    private static func filterSFSymbol(for type: FileClient.FilterType) -> String {
        switch type {
        case .all: return "line.3.horizontal.decrease"
        case .images: return "photo"
        case .videos: return "film"
        case .audio: return "music.note"
        case .documents: return "doc.text"
        }
    }

    private var selectionTotalSize: Int64 {
        selection.compactMap { client.visibleByID[$0]?.size }
            .reduce(Int64(0), +)
    }

    /// Files or folders can be downloaded (folders recursively).
    private var selectionContainsDownloadable: Bool {
        selection.contains { id in client.visibleByID[id] != nil }
    }

    private func dragOutProvider(for entry: DirEntry) -> NSItemProvider {
        FileBrowserTransfers.dragOutProvider(client: client, entry: entry, selection: selection)
    }

    private func copySelectedPaths() {
        let paths = client.visibleEntries
            .filter { selection.contains($0.id) }
            .map {
                client.absoluteDevicePath(
                    relative: client.child(of: client.currentPath, name: $0.name)
                )
            }
        guard !paths.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths.joined(separator: "\n"), forType: .string)
    }

    private func installApk() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose an APK to install on the device")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let serial = engine.deviceSerial
        let path = url.path
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try AdbAppManager.shared.installApk(serial: serial, localPath: path)
                }.value
                client.error = nil
            } catch {
                client.error = error.localizedDescription
            }
        }
    }

    // MARK: - Actions

    private func downloadSelection(pickLocation: Bool = false) {
        FileBrowserTransfers.downloadSelection(
            client: client,
            selection: selection,
            pickLocation: pickLocation
        )
    }

    private func uploadFile() {
        FileBrowserTransfers.uploadWithOpenPanel(client: client)
    }

    private func handleDrop(providers: [NSItemProvider]) {
        FileBrowserTransfers.handleDrop(client: client, providers: providers)
    }
}
