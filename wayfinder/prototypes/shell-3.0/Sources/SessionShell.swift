import SwiftUI

/// Flow B — active session workspace per shell-and-ia.md.
struct SessionShell: View {
    @Bindable var state: PrototypeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        VStack(spacing: 0) {
            PrototypeBanner()
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
            } content: {
                fileBrowser
            } detail: {
                if state.showInspector {
                    inspector
                } else {
                    ContentUnavailableView(
                        "Inspector hidden",
                        systemImage: "sidebar.right",
                        description: Text("Toggle from toolbar")
                    )
                }
            }
            statusBar
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $state.showTransfers) {
            transferSheet
        }
        .overlay(alignment: .topTrailing) {
            if state.showMirrorPanel {
                mirrorPanel
                    .padding()
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if state.showCommandPalette {
                commandPalette
            }
        }
        .animation(ProtoMotion.meso(reduceMotion: reduceMotion), value: state.showMirrorPanel)
        .animation(ProtoMotion.meso(reduceMotion: reduceMotion), value: state.showCommandPalette)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding(
            get: { state.activeDeviceID },
            set: { if let id = $0 { state.selectDevice(id) } }
        )) {
            Section("Devices") {
                ForEach(state.devices) { device in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text(device.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Circle()
                            .fill(device.online ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                    }
                    .tag(device.id)
                }
            }
            Section("Locations") {
                ForEach(Fixtures.locations, id: \.self) { loc in
                    Button {
                        state.openLocation(loc)
                    } label: {
                        Label(loc, systemImage: "folder")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        .navigationTitle("DroidMate")
    }

    // MARK: Browser

    private var fileBrowser: some View {
        VStack(spacing: 0) {
            pathBar
            ZStack(alignment: .top) {
                fileList
                if state.isNavigating {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Opening…")
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    // Chip only — list stays fully opaque (motion + shell contract).
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 360, ideal: 480)
    }

    private var pathBar: some View {
        HStack(spacing: 8) {
            Text(state.path)
                .font(.callout.monospaced())
                .lineLimit(1)
            Spacer()
            if state.isNavigating {
                Text("Navigating")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private var fileList: some View {
        List(selection: $state.selectedIDs) {
            ForEach(state.entries) { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.isDir ? "folder.fill" : "doc")
                        .foregroundStyle(entry.isDir ? Color.accentColor : .secondary)
                        .frame(width: 20)
                    Text(entry.name)
                    Spacer()
                    Text(entry.sizeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                    Text(entry.dateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .trailing)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .listRowBackground(
                    SoftSelectionBackground(selected: state.selectedIDs.contains(entry.id))
                        // P1: no animation on selection chrome
                        .animation(nil, value: state.selectedIDs)
                )
                .tag(entry.id)
                .onTapGesture(count: 2) {
                    state.openEntry(entry)
                }
            }
        }
        .listStyle(.inset)
        // Keep list readable while navigating — no opacity dim on whole list.
        .opacity(1)
    }

    // MARK: Inspector

    private var inspector: some View {
        Group {
            if let entry = state.selectedEntry {
                Form {
                    LabeledContent("Name", value: entry.name)
                    LabeledContent("Kind", value: entry.isDir ? "Folder" : "File")
                    LabeledContent("Size", value: entry.sizeText)
                    LabeledContent("Modified", value: entry.dateText)
                    LabeledContent("Path", value: "\(state.path)/\(entry.name)")
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Select a file to inspect")
                )
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 320)
    }

    // MARK: Status

    private var statusBar: some View {
        HStack(spacing: 16) {
            Text("\(state.entries.count) items")
                .font(.caption)
            if state.selectedIDs.isEmpty == false {
                Text("\(state.selectedIDs.count) selected")
                    .font(.caption)
            }
            Spacer()
            // Fixed-width-ish transfer summary (P4 discipline — static in prototype).
            Text("↓ 12 MB/s")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 72, alignment: .trailing)
            Text("62%")
                .font(.caption.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
            Text(state.statusNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                state.showInspector.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .help("Toggle inspector")

            Button {
                state.showTransfers = true
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle")
            }
            .help("Transfers (⌘J)")
            .keyboardShortcut("j", modifiers: .command)

            Button {
                withAnimation(ProtoMotion.meso(reduceMotion: reduceMotion)) {
                    state.showMirrorPanel.toggle()
                }
            } label: {
                Image(systemName: "rectangle.dashed.badge.record")
            }
            .help("Mirror controls")

            Button {
                withAnimation(ProtoMotion.meso(reduceMotion: reduceMotion)) {
                    state.showCommandPalette = true
                }
            } label: {
                Image(systemName: "command")
            }
            .help("Command palette")
            .keyboardShortcut("k", modifiers: .command)

            Button("Disconnect") {
                withAnimation(ProtoMotion.macro(reduceMotion: reduceMotion)) {
                    state.disconnectToWorkbench()
                }
            }
        }
    }

    // MARK: Summonable surfaces

    private var transferSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { state.showTransfers = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            List {
                ForEach(Array(Fixtures.fakeTransfers.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(row.0).font(.body.weight(.medium))
                            Spacer()
                            Text(row.1).font(.caption).foregroundStyle(.secondary)
                        }
                        ProgressView(value: row.2)
                            // No spring on progress (motion language).
                            .animation(nil, value: row.2)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }

    private var mirrorPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mirror controls")
                .font(.headline)
            Text("scrcpy opens in an external window — not embedded.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Start") { state.statusNote = "Would launch scrcpy (stub)" }
                Button("Stop") { state.statusNote = "Would stop scrcpy (stub)" }
                Picker("Quality", selection: .constant("Balanced")) {
                    Text("Balanced").tag("Balanced")
                    Text("High").tag("High")
                }
                .frame(width: 120)
            }
            Button("Close") {
                withAnimation(ProtoMotion.meso(reduceMotion: reduceMotion)) {
                    state.showMirrorPanel = false
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(radius: 8, y: 4)
    }

    private var commandPalette: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(ProtoMotion.meso(reduceMotion: reduceMotion)) {
                        state.showCommandPalette = false
                    }
                }
            VStack(alignment: .leading, spacing: 0) {
                Text("Command palette (stub)")
                    .font(.headline)
                    .padding()
                Divider()
                ForEach(["Go to Download", "Show transfers", "Start mirror", "Disconnect"], id: \.self) { cmd in
                    Button(cmd) {
                        state.statusNote = "⌘K · \(cmd)"
                        withAnimation(ProtoMotion.meso(reduceMotion: reduceMotion)) {
                            state.showCommandPalette = false
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
            }
            .frame(width: 400)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(radius: 20, y: 10)
        }
    }
}
