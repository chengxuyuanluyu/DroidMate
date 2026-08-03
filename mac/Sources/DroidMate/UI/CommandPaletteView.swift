import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// ⌘K command palette. Fuzzy-filtered, keyboard-navigable, grouped.
/// Open via Cmd+K, type to filter, ↑↓ to navigate, Enter to fire.
struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    let connMgr: ConnectionManager


    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    /// True when the last selection change came from keyboard navigation —
    /// only then scroll the selection into view. Mouse hover targets are
    /// already visible, so scrolling there would yank the list.
    @State private var scrollToSelection = false
    @FocusState private var focused: Bool

    private var engine: DeviceSession? { connMgr.activeEngine }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Type a command…", text: $query)
                    .submitLabel(.go)
                    .onSubmit { run(at: selectedIndex) }
                    .focused($focused)
            }
            .padding(12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let groups = groupedFiltered
                        ForEach(groups, id: \.0) { groupName, items in
                            Section {
                                ForEach(items, id: \.id) { cmd in
                                    let idx = flatIndex(of: cmd)
                                    row(cmd, isSelected: idx == selectedIndex)
                                        // Explicit .id so ScrollViewReader can
                                        // find the row (ForEach id: alone is not
                                        // enough — same fix as the breadcrumb).
                                        .id(cmd.id)
                                        .onHover { hovering in
                                            if hovering { selectedIndex = idx }
                                        }
                                        .onTapGesture { run(at: idx) }
                                }
                            } header: {
                                if !groupName.isEmpty {
                                    Text(groupName)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 12)
                                        .padding(.top, 8)
                                        .padding(.bottom, 4)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
                .onChange(of: selectedIndex) { _, newIndex in
                    guard scrollToSelection else { return }
                    scrollToSelection = false
                    guard newIndex >= 0, newIndex < flatFiltered.count else { return }
                    withAnimation(nil) { proxy.scrollTo(flatFiltered[newIndex].id, anchor: .center) }
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DM.Radius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DM.Radius.xl, style: .continuous)
                .strokeBorder(DM.cardStroke, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(DM.isDark ? 0.45 : 0.12), radius: 24, y: 10)
        .frame(width: 540)
        .padding()
        .focusable()
        .onKeyPress(.upArrow) { move(by: -1); return .handled }
        .onKeyPress(.downArrow) { move(by: 1); return .handled }
        .onKeyPress(.escape) { isPresented = false; return .handled }
        .onAppear { focused = true; selectedIndex = 0 }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ cmd: Command, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: cmd.icon)
                .frame(width: 20)
                .foregroundStyle(.tint)
            highlightedTitle(cmd.title)
            Spacer()
            if let shortcut = cmd.shortcut {
                Text(shortcut)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, DM.Space.md)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: DM.Radius.sm, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
    }

    /// Bolds the parts of `title` that match the fuzzy query.
    @ViewBuilder
    private func highlightedTitle(_ title: String) -> some View {
        let ranges = fuzzyMatchedRanges(query: query, in: title)
        if ranges.isEmpty {
            Text(title)
        } else {
            Text(attributed(title, highlight: ranges))
        }
    }

    private func attributed(_ s: String, highlight ranges: [Range<Int>]) -> AttributedString {
        var attr = AttributedString(s)
        for r in ranges {
            let lower = attr.index(attr.startIndex, offsetByCharacters: r.lowerBound)
            let upper = attr.index(attr.startIndex, offsetByCharacters: r.upperBound)
            attr[lower..<upper].font = .body.weight(.semibold)
            attr[lower..<upper].foregroundColor = .primary
        }
        return attr
    }

    // MARK: - Selection

    private func move(by delta: Int) {
        let n = flatFiltered.count
        guard n > 0 else { return }
        let newIndex = (selectedIndex + delta).clamped(to: 0...(n - 1))
        // Only ask to scroll when the index actually moves — at the list ends
        // the clamp keeps it unchanged and a stale flag would make the next
        // hover / query reset yank the list to center.
        if newIndex != selectedIndex { scrollToSelection = true }
        selectedIndex = newIndex
    }

    private func run(at index: Int) {
        guard flatFiltered.indices.contains(index) else { return }
        flatFiltered[index].action()
        isPresented = false
    }

    private func flatIndex(of cmd: Command) -> Int {
        flatFiltered.firstIndex(where: { $0.id == cmd.id }) ?? 0
    }

    // MARK: - Commands

    private struct Command: Identifiable {
        enum Group: String, CaseIterable {
            case navigation = "Navigation"
            case files      = "Files"
            case device     = "Device"
            case settings   = "Settings"
        }
        let id: String
        let title: String
        let icon: String
        let shortcut: String?
        let group: Group
        let action: () -> Void

        init(title: String, icon: String, shortcut: String?, group: Group, action: @escaping () -> Void) {
            self.id = title
            self.title = title
            self.icon = icon
            self.shortcut = shortcut
            self.group = group
            self.action = action
        }
    }

    private var allCommands: [Command] {
        guard let engine = connMgr.activeEngine else {
            return [
                Command(title: "Refresh devices", icon: "arrow.clockwise", shortcut: "⇧⌘R", group: .device) {
                    NotificationCenter.default.post(name: .refreshDevices, object: nil)
                },
            ]
        }
        let client = engine.files
        var cmds: [Command] = []

        // Navigation
        cmds += [
            Command(title: "Refresh File List", icon: "arrow.clockwise", shortcut: "⌘R", group: .navigation) {
                Task { await client.refresh() }
            },
            Command(title: "Back", icon: "chevron.left", shortcut: "⌘[", group: .navigation) {
                Task { await client.goBack() }
            },
            Command(title: "Forward", icon: "chevron.right", shortcut: "⌘]", group: .navigation) {
                Task { await client.goForward() }
            },
            Command(title: "Go Up", icon: "arrow.up", shortcut: "⌘↑", group: .navigation) {
                Task { await client.goUp() }
            },
            Command(title: "Go to Root", icon: "internaldrive", shortcut: nil, group: .navigation) {
                Task { await client.list(path: "/") }
            },
            Command(title: "Go to Path…", icon: "text.cursor", shortcut: "⇧⌘G", group: .navigation) {
                NotificationCenter.default.post(name: .showGoToPath, object: nil)
            },
            Command(title: "Focus Search", icon: "magnifyingglass", shortcut: "⌘F", group: .navigation) {
                NotificationCenter.default.post(name: .focusSearch, object: nil)
            },
            Command(title: "Export Diagnostics…", icon: "stethoscope", shortcut: nil, group: .device) {
                _ = DiagnosticsExporter.exportAndReveal()
            },
        ]
        for (name, icon) in [("Download", "arrow.down.circle"), ("DCIM", "camera"),
                             ("Pictures", "photo"), ("Documents", "doc.text"),
                             ("Music", "music.note"), ("Movies", "film")] {
            cmds.append(Command(title: "Go to \(name)", icon: icon, shortcut: nil, group: .navigation) {
                Task { await client.list(path: name) }
            })
        }
        for path in client.pinnedPaths() {
            let label = path == "/" ? "Files" : (path.split(separator: "/").last.map(String.init) ?? path)
            cmds.append(Command(title: "Go to pin: \(label)", icon: "star.fill", shortcut: nil, group: .navigation) {
                Task { await client.list(path: path) }
            })
        }
        for path in client.recentPaths().prefix(4) {
            let label = path == "/" ? "Files" : (path.split(separator: "/").last.map(String.init) ?? path)
            cmds.append(Command(title: "Recent: \(label)", icon: "clock", shortcut: nil, group: .navigation) {
                Task { await client.list(path: path) }
            })
        }

        // Files
        cmds += [
            Command(title: "Upload File…", icon: "arrow.up.doc", shortcut: nil, group: .files) {
                uploadFile(client: client)
            },
            Command(title: "New Folder", icon: "folder.badge.plus", shortcut: "⇧⌘N", group: .files) {
                NotificationCenter.default.post(name: .newFolder, object: nil)
            },
            Command(title: "Toggle List / Grid", icon: "square.grid.2x2", shortcut: nil, group: .files) {
                NotificationCenter.default.post(name: .toggleViewMode, object: nil)
            },
            Command(title: "Toggle Hidden Files", icon: "eye", shortcut: nil, group: .files) {
                client.showHidden.toggle()
            },
            Command(title: client.isPinned(client.currentPath) ? "Unpin Current Folder" : "Pin Current Folder",
                    icon: client.isPinned(client.currentPath) ? "star.slash" : "star",
                    shortcut: nil, group: .files) {
                client.togglePinned(client.currentPath)
            },
            Command(title: "Transfer Queue…", icon: "arrow.left.arrow.right.circle", shortcut: nil, group: .files) {
                NotificationCenter.default.post(name: .openTransfers, object: nil)
            },
            Command(title: "Manage Apps", icon: "square.grid.3d", shortcut: nil, group: .files) {
                NotificationCenter.default.post(name: .openAppManager, object: nil)
            },
        ]
        if client.isTransferring {
            cmds.append(Command(title: "Pause All Transfers", icon: "pause.circle", shortcut: nil, group: .files) {
                client.pauseAllTransfers()
            })
        }
        let retryable = client.transferEngine.transferHistory.filter(\.canRetry)
        if !retryable.isEmpty {
            cmds.append(Command(
                title: "Retry Failed/Paused Transfers (\(retryable.count))",
                icon: "arrow.clockwise",
                shortcut: nil,
                group: .files
            ) {
                Task {
                    for record in retryable {
                        _ = await client.retryTransfer(record)
                    }
                }
            })
        }
        if client.transferEngine.transferHistory.contains(where: { $0.status == .completed }) {
            cmds.append(Command(title: "Clear Completed Transfers", icon: "trash", shortcut: nil, group: .files) {
                client.transferEngine.clearCompletedHistory()
            })
        }
        if client.canPaste {
            cmds.append(Command(title: "Paste", icon: "doc.on.clipboard", shortcut: "⌘V", group: .files) {
                Task { await client.paste() }
            })
        }
        cmds.append(Command(title: "Clear Recent Folders", icon: "clock.badge.xmark", shortcut: nil, group: .files) {
            client.clearRecentPaths()
        })

        // Device
        cmds += [
            Command(title: "Reconnect Device", icon: "arrow.triangle.2.circlepath", shortcut: nil, group: .device) {
                Task {
                    do {
                        try await connMgr.recover(serial: engine.deviceSerial)
                    } catch is CancellationError {
                        // Session recovered or app is shutting down.
                    } catch {
                        // Operational failures are reflected by recoveryPhase.
                    }
                }
            },
            Command(title: "Disconnect", icon: "antenna.radiowaves.left.and.right.slash",
                    shortcut: "⌘D", group: .device) {
                connMgr.requestDisconnect(engine.deviceSerial)
            },
            Command(title: "Copy Device Serial", icon: "doc.on.doc", shortcut: nil, group: .device) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(engine.deviceSerial, forType: .string)
            },
        ]

        // Settings
        cmds += [
            Command(title: "Open Settings…", icon: "gear", shortcut: "⌘,", group: .settings) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            },
            Command(title: "What's New…", icon: "sparkles", shortcut: nil, group: .settings) {
                NotificationCenter.default.post(name: .showWhatsNew, object: nil)
            },
            Command(title: "Show Download Folder", icon: "folder", shortcut: nil, group: .settings) {
                let path: String = {
                    if let last = UserDefaults.standard.string(forKey: "lastDownloadDir"),
                       FileManager.default.fileExists(atPath: last) {
                        return last
                    }
                    return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
                }()
                NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
            },
        ]

        return cmds
    }

    /// Scored command (keeps score out of `allCommands` for sort stability).
    private struct ScoredCmd {
        let cmd: Command
        let score: Int
    }

    /// Flat filtered + sorted list (used for keyboard navigation).
    private var flatFiltered: [Command] {
        guard !query.isEmpty else { return allCommands }
        return allCommands
            .compactMap { cmd -> ScoredCmd? in
                guard let score = fuzzyScore(query: query, target: cmd.title) else { return nil }
                return ScoredCmd(cmd: cmd, score: score)
            }
            .sorted { $0.score > $1.score }
            .map(\.cmd)
    }

    /// Same items regrouped by section header (used for display).
    private var groupedFiltered: [(String, [Command])] {
        let order: [Command.Group] = Command.Group.allCases
        return order.compactMap { g in
            let items = flatFiltered.filter { $0.group == g }
            return items.isEmpty ? nil : (g.rawValue, items)
        }
    }

    private func uploadFile(client: FileClient) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await client.upload(localURL: url) }
    }
}
