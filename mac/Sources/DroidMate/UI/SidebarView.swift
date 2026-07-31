import AppKit
import SwiftUI

/// Left column of the NavigationSplitView: device list, locations, disconnect.
/// Custom rows instead of List — a Button inside a List row only gets hits on
/// its label's width, so clicks on the row's empty right side were swallowed
/// (the old "taps sometimes do nothing" bug). These rows fill the full width.
struct SidebarView: View {
    @ObservedObject var connMgr: ConnectionManager
    @ObservedObject var engine: DeviceSession
    @ObservedObject var client: FileClient
    var serial: String?
    @ObservedObject var scrcpy: ScrcpyController

    @State private var battery: Int?
    @State private var storageText: String?
    @State private var showAddDevice = false
    @State private var showDisconnectConfirm = false
    @State private var disconnectTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SidebarDevicesSection(
                        connMgr: connMgr,
                        engine: engine,
                        scrcpy: scrcpy,
                        disconnectTarget: $disconnectTarget,
                        showDisconnectConfirm: $showDisconnectConfirm,
                        battery: battery,
                        storageText: storageText
                    )
                    SidebarLocationsSection(client: client)
                }
                .padding(.horizontal, 10)
                .padding(.top, 12)
            }
            Divider()
            disconnectFooter
        }
        .task(id: engine.deviceSerial) {
            while !Task.isCancelled {
                battery = AdbBridge.shared.getBatteryLevel(serial: engine.deviceSerial)
                if let s = AdbBridge.shared.getStorageInfo(serial: engine.deviceSerial) {
                    let used = ByteCountFormatter.string(fromByteCount: s.usedBytes, countStyle: .file)
                    let total = ByteCountFormatter.string(fromByteCount: s.totalBytes, countStyle: .file)
                    storageText = "\(used) / \(total)"
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // MARK: - Footer

    private var disconnectFooter: some View {
        VStack(spacing: 8) {
            Button {
                showAddDevice = true
            } label: {
                Label("Add Device", systemImage: "plus.circle")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(role: .destructive) {
                requestDisconnect()
            } label: {
                Label("Disconnect", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(connMgr.engines.isEmpty)
        }
        .padding(.horizontal, DM.Space.md)
        .padding(.vertical, DM.Space.md)
        .background(.bar)
        .confirmationDialog(
            "Disconnect this device?",
            isPresented: $showDisconnectConfirm,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                performDisconnect()
            }
            Button("Cancel", role: .cancel) {
                disconnectTarget = nil
            }
        } message: {
            let target = disconnectTarget.flatMap { serial in
                connMgr.engines.first(where: { $0.deviceSerial == serial })
            } ?? engine
            if target.files.isTransferring {
                Text("Transfers are still in progress. Disconnecting will cancel them.")
            } else {
                Text("You can reconnect anytime from the connection screen.")
            }
        }
        .sheet(isPresented: $showAddDevice) {
            NavigationStack {
                ConnectionView(connMgr: connMgr)
                    .navigationTitle("Add Device")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showAddDevice = false }
                        }
                    }
            }
            .frame(minWidth: 480, minHeight: 520)
        }
        .onChange(of: connMgr.engines.count) { old, new in
            if new > old { showAddDevice = false }
        }
    }

    private func requestDisconnect() {
        disconnectTarget = connMgr.activeEngine?.deviceSerial
        if engine.files.isTransferring {
            showDisconnectConfirm = true
        } else {
            performDisconnect()
        }
    }

    private func performDisconnect() {
        let serial = disconnectTarget ?? connMgr.activeEngine?.deviceSerial
        if let serial {
            connMgr.disconnect(serial)
        }
        disconnectTarget = nil
    }
}
