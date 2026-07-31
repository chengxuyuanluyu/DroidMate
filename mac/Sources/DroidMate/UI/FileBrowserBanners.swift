import SwiftUI

/// Session recovery / transport-health strip above the file list.
struct FileBrowserSessionBanner: View {
    @ObservedObject var engine: DeviceSession
    @ObservedObject var connMgr: ConnectionManager
    @ObservedObject var scrcpy: ScrcpyController

    var body: some View {
        VStack(spacing: 0) {
            recoveryContent
            if let status = scrcpy.launchStatusText, !status.isEmpty,
               scrcpy.launchingSerials.contains(engine.deviceSerial) {
                FileBrowserBannerBar(
                    transportState: engine.transportState,
                    icon: "airplayvideo",
                    color: .accentColor,
                    message: status,
                    actionTitle: String(localized: "Cancel"),
                    action: { scrcpy.stop(serial: engine.deviceSerial) }
                )
            }
            if let hint = scrcpy.controlHint, !hint.isEmpty {
                FileBrowserBannerBar(
                    transportState: engine.transportState,
                    icon: "hand.raised.fill",
                    color: .orange,
                    message: hint,
                    actionTitle: String(localized: "Dismiss"),
                    action: { scrcpy.clearControlHint() }
                )
            }
            if let err = scrcpy.launchError, !err.isEmpty {
                FileBrowserBannerBar(
                    transportState: engine.transportState,
                    icon: "exclamationmark.triangle.fill",
                    color: .red,
                    message: err,
                    actionTitle: String(localized: "OK"),
                    action: { scrcpy.clearLaunchError() }
                )
            }
        }
    }

    @ViewBuilder
    private var recoveryContent: some View {
        switch engine.recoveryPhase {
        case .recovering(_, let detail):
            FileBrowserBannerBar(
                transportState: engine.transportState,
                icon: "arrow.triangle.2.circlepath",
                color: .orange,
                message: detail,
                actionTitle: nil,
                action: nil
            )
        case .gaveUp(let detail):
            FileBrowserBannerBar(
                transportState: engine.transportState,
                icon: "exclamationmark.triangle.fill",
                color: .red,
                message: detail,
                actionTitle: String(localized: "Reconnect"),
                action: {
                    Task { await connMgr.recover(serial: engine.deviceSerial) }
                }
            )
        case .idle:
            switch engine.transportState {
            case .connecting, .handshaking, .disconnected:
                if engine.ack == nil || !engine.isSessionReady {
                    FileBrowserBannerBar(
                        transportState: engine.transportState,
                        icon: "antenna.radiowaves.left.and.right",
                        color: .orange,
                        message: String(localized: "Connecting to device…"),
                        actionTitle: nil,
                        action: nil
                    )
                }
            case .failed(let msg):
                let link = engine.isWireless
                    ? String(localized: "Wi‑Fi session interrupted")
                    : String(localized: "USB session interrupted")
                FileBrowserBannerBar(
                    transportState: engine.transportState,
                    icon: "exclamationmark.triangle.fill",
                    color: .red,
                    message: "\(link) — \(msg)",
                    actionTitle: String(localized: "Reconnect"),
                    action: {
                        Task { await connMgr.recover(serial: engine.deviceSerial) }
                    }
                )
            case .ready:
                EmptyView()
            }
        }
    }
}

/// Soft tip when a directory is huge — search/filter is the practical path.
struct FileBrowserLargeFolderHint: View {
    @ObservedObject var client: FileClient
    var onFocusSearch: () -> Void

    var body: some View {
        if client.entries.count >= FileClient.largeFolderThreshold,
           client.searchQuery.isEmpty,
           client.filterType == .all {
            HStack(spacing: DM.Space.sm) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.orange.opacity(0.85))
                Text(String(localized: "Large folder (\(client.entries.count) items). Search or filter to keep the list snappy."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("Images") { client.filterType = .images }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Videos") { client.filterType = .videos }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Search", action: onFocusSearch)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, DM.Space.md)
            .padding(.vertical, DM.Space.sm)
            .background(Color.orange.opacity(0.07))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.orange.opacity(0.15)).frame(height: 0.5)
            }
        }
    }
}

// MARK: - Shared banner chrome

private struct FileBrowserBannerBar: View {
    let transportState: TransportClient.ConnectionState
    let icon: String
    let color: Color
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: DM.Space.sm) {
            if transportState == .connecting || transportState == .handshaking {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 18)
            }
            Text(message)
                .font(.callout)
                .lineLimit(4)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DM.Space.sm)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, DM.Space.md)
        .padding(.vertical, DM.Space.sm + 2)
        .background(
            RoundedRectangle(cornerRadius: DM.Radius.md, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: DM.Radius.md, style: .continuous)
                        .strokeBorder(color.opacity(0.32), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, DM.Space.md)
        .padding(.top, DM.Space.sm)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }
}
