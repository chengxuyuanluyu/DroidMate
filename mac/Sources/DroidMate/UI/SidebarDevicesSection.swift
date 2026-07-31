import AppKit
import SwiftUI

/// Device list + live battery/storage info for the file-browser sidebar.
struct SidebarDevicesSection: View {
    @ObservedObject var connMgr: ConnectionManager
    @ObservedObject var engine: DeviceSession
    @ObservedObject var scrcpy: ScrcpyController
    @Binding var disconnectTarget: String?
    @Binding var showDisconnectConfirm: Bool

    var battery: Int?
    var storageText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            devicesList
            if connMgr.activeEngine != nil {
                deviceInfo
            }
        }
    }

    private var devicesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            sidebarSectionHeader("Devices")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(connMgr.engines, id: \.deviceSerial) { dev in
                    deviceRow(dev)
                }
            }
        }
    }

    private func deviceRow(_ dev: DeviceSession) -> some View {
        let isActive = connMgr.activeDeviceId == dev.deviceSerial
            || (connMgr.activeDeviceId == nil && connMgr.engines.first?.deviceSerial == dev.deviceSerial)
        let isFailed: Bool = {
            if case .failed = dev.transportState { return true }
            return false
        }()
        return Button {
            if isFailed {
                connMgr.reconnect(dev.deviceSerial)
            } else {
                connMgr.switchTo(dev.deviceSerial)
            }
        } label: {
            HStack(spacing: DM.Space.sm) {
                Circle()
                    .fill(statusColor(dev))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(dev.displayName)
                        .font(.callout.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isFailed {
                        Text("Tap to reconnect")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else if !dev.isSessionReady {
                        Text("Connecting…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 4) {
                            Text(dev.transportLabel)
                            if let version = dev.ack?.androidVersion {
                                Text("·")
                                Text(String(format: String(localized: "Android %@"), version))
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if isActive && dev.isSessionReady {
                    Text("\(dev.rttMs, specifier: "%.0f") ms")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, DM.Space.sm)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sidebarRowBackground(isActive: isActive)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
        .help(dev.deviceSerial)
        .contextMenu {
            deviceContextMenu(dev)
        }
    }

    @ViewBuilder
    private func deviceContextMenu(_ dev: DeviceSession) -> some View {
        Button {
            connMgr.switchTo(dev.deviceSerial)
        } label: {
            Label("Switch to This Device", systemImage: "checkmark.circle")
        }
        .disabled(connMgr.activeDeviceId == dev.deviceSerial)

        Button {
            Task { await connMgr.recover(serial: dev.deviceSerial) }
        } label: {
            Label("Reconnect", systemImage: "arrow.clockwise")
        }

        if scrcpy.runningSerials.contains(dev.deviceSerial) {
            Button {
                scrcpy.stop(serial: dev.deviceSerial)
            } label: {
                Label(
                    scrcpy.isLaunching(serial: dev.deviceSerial)
                        ? String(localized: "Cancel Mirror")
                        : String(localized: "Stop Mirror"),
                    systemImage: "stop.fill"
                )
            }
        } else {
            Button {
                connMgr.switchTo(dev.deviceSerial)
                _ = scrcpy.startMirror(
                    serial: dev.deviceSerial,
                    deviceModel: dev.ack?.deviceModel,
                    recordSession: false
                )
            } label: {
                Label("Start Mirror", systemImage: "airplayvideo")
            }
            .disabled(dev.ack == nil || !scrcpy.isScrcpyAvailable)

            Button {
                connMgr.switchTo(dev.deviceSerial)
                _ = scrcpy.startMirror(
                    serial: dev.deviceSerial,
                    deviceModel: dev.ack?.deviceModel,
                    recordSession: true
                )
            } label: {
                Label("Start Mirror & Record", systemImage: "record.circle")
            }
            .disabled(dev.ack == nil || !scrcpy.isScrcpyAvailable)
        }

        Divider()

        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(dev.deviceSerial, forType: .string)
        } label: {
            Label("Copy Serial", systemImage: "doc.on.doc")
        }

        if dev.isWireless {
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(dev.deviceSerial, forType: .string)
            } label: {
                Label("Copy Endpoint", systemImage: "wifi")
            }
        }

        Divider()

        Button(role: .destructive) {
            disconnectTarget = dev.deviceSerial
            if dev.files.isTransferring {
                showDisconnectConfirm = true
            } else {
                connMgr.disconnect(dev.deviceSerial)
                disconnectTarget = nil
            }
        } label: {
            Label("Disconnect", systemImage: "antenna.radiowaves.left.and.right.slash")
        }
    }

    private var deviceInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            sidebarSectionHeader("Device Info")
            VStack(alignment: .leading, spacing: 4) {
                infoRow("Link", engine.transportLabel)
                if engine.isWireless {
                    infoRow("Endpoint", engine.deviceSerial)
                }
                if let battery {
                    infoRow("Battery", "\(battery)%")
                }
                if let storageText {
                    infoRow("Storage", storageText)
                }
                if engine.isSessionReady {
                    infoRow("RTT", String(format: "%.0f ms", engine.rttMs))
                }
            }
            .padding(.horizontal, DM.Space.sm)
            .padding(.vertical, DM.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DM.Radius.md, style: .continuous)
                    .fill(DM.panelFill)
            )
        }
    }

    private func statusColor(_ dev: DeviceSession) -> Color {
        switch dev.transportState {
        case .ready:
            if dev.rttMs < 50 { return .green }
            if dev.rttMs < 100 { return .orange }
            return .red
        case .connecting, .handshaking: return .orange
        case .failed: return .red
        case .disconnected: return .secondary
        }
    }

    @ViewBuilder
    private func infoRow(_ k: LocalizedStringKey, _ v: String) -> some View {
        HStack(spacing: DM.Space.sm) {
            Text(k)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            Text(v)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
