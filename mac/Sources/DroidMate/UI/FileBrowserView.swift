import SwiftUI
import UniformTypeIdentifiers

/// Connected session workspace (docs/3.0/shell-and-ia.md).
///
/// Shell: `NavigationSplitView` (Devices + Locations | browser) + collapsible
/// trailing **inspector**. Engines stay wired through existing
/// `ConnectionManager` / `DeviceSession` / `FileClient` — no protocol rewrite.
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
    /// 3.0 shell: inspector is progressive disclosure (default on).
    @AppStorage("ui.inspector_visible") private var showInspector = true

    @State private var showDeleteConfirm = false
    @State private var showNewFolder = false
    @State private var newFolderText = ""
    @State private var showGoToPath = false
    @State private var goToPathText = ""
    /// Entry currently being renamed inline. When set, the row swaps its name
    /// label for a focused TextField. nil = no inline edit active.
    @State private var renamingID: DirEntry.ID?
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Two-column split + trailing inspector (collapsible). Avoid a permanent
        // third NavigationSplit column so hide/show does not rebuild the file list.
        NavigationSplitView {
            SidebarView(connMgr: connMgr, engine: engine, client: client, serial: serial, scrcpy: scrcpy)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            // Child observes FileClient (+ session banner needs engine). Parent still
            // owns selection/sheets so scrcpy ticks do not re-measure the whole split.
            FileBrowserMainColumn(
                connMgr: connMgr,
                engine: engine,
                client: client,
                scrcpy: scrcpy,
                selection: $selection,
                renamingID: $renamingID,
                viewMode: $viewMode,
                searchFocused: $searchFocused,
                dropTargeted: $dropTargeted,
                dropItemCount: $dropItemCount,
                showDeleteConfirm: $showDeleteConfirm,
                showTransfers: $showTransfers,
                reduceMotion: reduceMotion,
                onDownload: { downloadSelection(pickLocation: $0) },
                onUpload: { uploadFile() },
                onDragOut: { dragOutProvider(for: $0) },
                onCopyPaths: { copySelectedPaths() },
                onDrop: { handleDrop(providers: $0) }
            )
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $showInspector) {
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
            .inspectorColumnWidth(min: 200, ideal: 260, max: 360)
        }
        .navigationTitle("DroidMate")
        .navigationSubtitle(pathSubtitle)
        .toolbar {
            FileBrowserToolbar(
                client: client,
                engine: engine,
                scrcpy: scrcpy,
                transfers: client.transferEngine,
                viewMode: $viewMode,
                showNewFolder: $showNewFolder,
                newFolderText: $newFolderText,
                showTransfers: $showTransfers,
                showAppManager: $showAppManager,
                showInspector: $showInspector,
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
            // Observe TransferEngine only inside the sheet (P4 — not FileBrowser list).
            NavigationStack {
                TransferQueueView(
                    client: client,
                    transfers: client.transferEngine,
                    onDismiss: { showTransfers = false }
                )
            }
            .frame(minWidth: 520, minHeight: 360)
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
        .onReceive(NotificationCenter.default.publisher(for: .toggleInspector)) { _ in
            showInspector.toggle()
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
                // Finder-style view / visibility shortcuts.
                Button("List View") { viewMode = .list }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Grid View") { viewMode = .grid }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Toggle Hidden Files") { client.showHidden.toggle() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Transfer Queue") { showTransfers = true }
                    .keyboardShortcut("j", modifiers: .command)
                Button("Toggle Inspector") { showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
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

    private var pathSubtitle: String {
        // Device model is already shown in the sidebar header — don't repeat
        // it here. Show only the current folder name so subtitle never truncates.
        guard client.currentPath != "/" else { return "" }
        return client.currentPath.split(separator: "/").last.map(String.init) ?? ""
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
