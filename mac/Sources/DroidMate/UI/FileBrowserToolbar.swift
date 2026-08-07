import SwiftUI

/// Window-level toolbar for the connected file browser.
/// Icon-only controls: full names live in `.help` / menu bodies so Chinese
/// titles never collapse to “新建…” / “安装…” in the bar itself.
struct FileBrowserToolbar: ToolbarContent {
    @ObservedObject var client: FileClient
    @ObservedObject var engine: DeviceSession
    @ObservedObject var scrcpy: ScrcpyController
    /// Observed only for queue badge (P4: progress ticks stay off the file list).
    @ObservedObject var transfers: TransferEngine

    @Binding var viewMode: ViewMode
    @Binding var showNewFolder: Bool
    @Binding var newFolderText: String
    @Binding var showTransfers: Bool
    @Binding var showAppManager: Bool
    @Binding var showInspector: Bool

    var selectionContainsDownloadable: Bool
    var onDownload: (_ pickLocation: Bool) -> Void
    var onUpload: () -> Void
    var onInstallApk: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showInspector.toggle()
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .help(showInspector
                  ? String(localized: "Hide Inspector")
                  : String(localized: "Show Inspector"))
            .accessibilityLabel(showInspector
                                ? String(localized: "Hide Inspector")
                                : String(localized: "Show Inspector"))

            // Isolated View so transfer progress publishes only re-badge this control.
            TransferQueueToolbarButton(transfers: transfers, showTransfers: $showTransfers)

            Picker("View", selection: $viewMode) {
                Label("List", systemImage: "list.bullet").tag(ViewMode.list)
                Label("Grid", systemImage: "square.grid.2x2").tag(ViewMode.grid)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Switch between list and grid view")

            Menu {
                Picker("Filter", selection: $client.filterType) {
                    ForEach(FileClient.FilterType.allCases, id: \.self) { type in
                        Label(filterTitle(type), systemImage: filterIcon(for: type)).tag(type)
                    }
                }
            } label: {
                Image(systemName: filterIcon(for: client.filterType))
            }
            .help("Filter by file type")

            Menu {
                ForEach(FileClient.SortKey.allCases, id: \.self) { key in
                    Button {
                        client.toggleSort(key)
                    } label: {
                        if client.sortKey == key {
                            Label(sortTitle(key), systemImage: "checkmark")
                        } else {
                            Text(sortTitle(key))
                        }
                    }
                }
                Divider()
                Picker("Direction", selection: $client.sortAscending) {
                    Label("Ascending", systemImage: "arrow.up").tag(true)
                    Label("Descending", systemImage: "arrow.down").tag(false)
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .help("Sort by")

            Divider()

            Menu {
                Button {
                    onDownload(false)
                } label: {
                    Label("Download to Downloads Folder", systemImage: "arrow.down.doc")
                }
                .keyboardShortcut("s", modifiers: .command)
                Button {
                    onDownload(true)
                } label: {
                    Label("Download to Chosen Folder…", systemImage: "folder.badge.plus")
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
            } label: {
                Image(systemName: "arrow.down.doc")
            }
            .disabled(client.isTransferring || !selectionContainsDownloadable)
            .help("Download to Downloads (⌘S). Choose folder with ⌥⌘S.")

            Button {
                Task { await client.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(client.isTransferring)
            .help("Refresh (⌘R)")

            if scrcpy.runningSerials.contains(engine.deviceSerial) {
                Menu {
                    Button {
                        scrcpy.stop(serial: engine.deviceSerial)
                    } label: {
                        Label("Stop Mirror", systemImage: "stop.fill")
                    }

                    Divider()

                    Button {
                        scrcpy.sendKey(serial: engine.deviceSerial, keycode: "KEYCODE_BACK")
                    } label: {
                        Label("Back", systemImage: "arrow.left")
                    }
                    .disabled(!scrcpy.isMirrorReady(serial: engine.deviceSerial))
                    Button {
                        scrcpy.sendKey(serial: engine.deviceSerial, keycode: "KEYCODE_HOME")
                    } label: {
                        Label("Home", systemImage: "house.fill")
                    }
                    .disabled(!scrcpy.isMirrorReady(serial: engine.deviceSerial))
                    Button {
                        scrcpy.sendKey(serial: engine.deviceSerial, keycode: "KEYCODE_APP_SWITCH")
                    } label: {
                        Label("Recents", systemImage: "square.fill")
                    }
                    .disabled(!scrcpy.isMirrorReady(serial: engine.deviceSerial))

                    Divider()

                    Button {
                        scrcpy.sendKey(serial: engine.deviceSerial, keycode: "KEYCODE_VOLUME_UP")
                    } label: {
                        Label("Volume Up", systemImage: "speaker.wave.2.fill")
                    }
                    .disabled(!scrcpy.isMirrorReady(serial: engine.deviceSerial))
                    Button {
                        scrcpy.sendKey(serial: engine.deviceSerial, keycode: "KEYCODE_VOLUME_DOWN")
                    } label: {
                        Label("Volume Down", systemImage: "speaker.wave.1.fill")
                    }
                    .disabled(!scrcpy.isMirrorReady(serial: engine.deviceSerial))
                    Button {
                        scrcpy.sendKey(serial: engine.deviceSerial, keycode: "KEYCODE_POWER")
                    } label: {
                        Label("Power", systemImage: "power")
                    }
                    .disabled(!scrcpy.isMirrorReady(serial: engine.deviceSerial))
                } label: {
                    if scrcpy.isLaunching(serial: engine.deviceSerial) {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "airplayvideo")
                            .foregroundStyle(.tint)
                    }
                }
                .help(scrcpy.isLaunching(serial: engine.deviceSerial)
                      ? (scrcpy.launchStatusText ?? String(localized: "Starting mirror…"))
                      : String(localized: "Mirror controls"))
            } else {
                Menu {
                    Button {
                        _ = scrcpy.startMirror(
                            serial: engine.deviceSerial,
                            deviceModel: engine.ack?.deviceModel,
                            recordSession: false
                        )
                    } label: {
                        Label("Start Mirror", systemImage: "airplayvideo")
                    }
                    Button {
                        _ = scrcpy.startMirror(
                            serial: engine.deviceSerial,
                            deviceModel: engine.ack?.deviceModel,
                            recordSession: true
                        )
                    } label: {
                        Label("Start Mirror & Record", systemImage: "record.circle")
                    }
                    .help("Same scrcpy session records until you stop the mirror (no 3-minute limit).")
                } label: {
                    Image(systemName: "airplayvideo")
                }
                .disabled(engine.ack == nil || !scrcpy.isScrcpyAvailable)
                .help("Start screen mirror")
            }

            Button {
                onUpload()
            } label: {
                Image(systemName: "arrow.up.doc")
            }
            .disabled(client.isTransferring)
            .help("Upload files or a folder to the current location")

            Button {
                newFolderText = ""
                showNewFolder = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("New Folder (⇧⌘N)")
            .keyboardShortcut("n", modifiers: [.command, .shift])

            // Full titles + icons so nothing collapses to “传输…” / “应用…”.
            Menu {
                Button {
                    onInstallApk()
                } label: {
                    Label("Install APK", systemImage: "app.badge.fill")
                }
                .disabled(engine.ack == nil)

                Button {
                    showAppManager = true
                } label: {
                    Label("Manage Apps", systemImage: "square.grid.2x2")
                }
                .disabled(engine.ack == nil)

                Divider()

                Toggle(isOn: $client.showHidden) {
                    Label("Show Hidden Files", systemImage: client.showHidden ? "eye" : "eye.slash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("More actions")
        }
    }

    private func filterIcon(for type: FileClient.FilterType) -> String {
        switch type {
        case .all: return "line.3.horizontal.decrease"
        case .images: return "photo"
        case .videos: return "film"
        case .audio: return "music.note"
        case .documents: return "doc.text"
        }
    }

    /// Toolbar/menu title — must be `LocalizedStringKey` (string literal path), not `rawValue`.
    private func filterTitle(_ type: FileClient.FilterType) -> LocalizedStringKey {
        switch type {
        case .all: return "All"
        case .images: return "Images"
        case .videos: return "Videos"
        case .audio: return "Audio"
        case .documents: return "Documents"
        }
    }

    private func sortTitle(_ key: FileClient.SortKey) -> LocalizedStringKey {
        switch key {
        case .name: return "Name"
        case .size: return "Size"
        case .modified: return "Modified"
        }
    }
}

/// Toolbar control for the transfer queue. Observes `TransferEngine` alone so
/// active-count badges update without rebuilding the file browser column.
private struct TransferQueueToolbarButton: View {
    @ObservedObject var transfers: TransferEngine
    @Binding var showTransfers: Bool

    var body: some View {
        Button {
            showTransfers = true
        } label: {
            if transfers.activeTransferCount > 0 {
                Label("\(transfers.activeTransferCount)", systemImage: "arrow.left.arrow.right.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .monospacedDigit()
            } else {
                Image(systemName: "arrow.left.arrow.right.circle")
            }
        }
        .help(transfers.activeTransferCount > 0
              ? String(localized: "Transfers (\(transfers.activeTransferCount))")
              : String(localized: "Transfer Queue"))
        .accessibilityLabel(String(localized: "Transfer Queue"))
        .accessibilityValue(transfers.activeTransferCount > 0
                            ? "\(transfers.activeTransferCount)"
                            : "")
        .keyboardShortcut("j", modifiers: .command)
    }
}
