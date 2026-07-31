import SwiftUI

/// Clickable ready-device row on the connection workspace.
struct ConnectionDeviceRow: View {
    let serial: String
    let isSelected: Bool
    let isRowConnecting: Bool
    let isConnected: Bool
    let isDisabled: Bool
    let onConnect: () -> Void

    var body: some View {
        Button(action: onConnect) {
            HStack(spacing: DM.Space.md) {
                ZStack {
                    Circle()
                        .fill(DM.Brand.softFill)
                        .frame(width: 36, height: 36)
                    Image(systemName: serial.contains(":") ? "wifi" : "iphone")
                        .font(.body.weight(.medium))
                        .foregroundStyle(DM.Brand.iconOnDark)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(serial)
                        .font(.body.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(isConnected ? .green : .secondary)
                }
                Spacer(minLength: 8)
                if isRowConnecting {
                    ProgressView().controlSize(.small)
                } else {
                    Text(isConnected ? "Open" : "Connect")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isConnected ? Color.green : Color.accentColor)
                    Image(systemName: isConnected ? "checkmark.circle.fill" : "chevron.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isConnected ? Color.green : Color.secondary)
                }
            }
            .padding(.horizontal, DM.Space.md)
            .padding(.vertical, DM.Space.md)
            .background(
                RoundedRectangle(cornerRadius: DM.Radius.lg, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : DM.panelFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DM.Radius.lg, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.45) : DM.cardStroke,
                        lineWidth: 0.5
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietRowButtonStyle())
        .disabled(isDisabled)
        .help(isConnected ? "Switch to this device in DroidMate" : "Start a DroidMate session")
    }

    private var subtitle: String {
        if isRowConnecting { return String(localized: "Connecting…") }
        let transport = serial.contains(":") ? String(localized: "Wi-Fi") : String(localized: "USB")
        if isConnected {
            return String(localized: "In use · \(transport)")
        }
        return transport
    }
}

/// Unauthorized / offline adb device with optional setup guide.
struct ConnectionUnauthorizedRow: View {
    let device: AdbBridge.DeviceInfo
    @Binding var showSetupGuide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.serial)
                        .font(.callout.monospaced())
                    Text(device.state == "unauthorized" ? "USB debugging required" : device.state.capitalized)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button(showSetupGuide ? "Hide" : "Setup Guide") {
                    withAnimation(AppSpring.standard) { showSetupGuide.toggle() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if showSetupGuide {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Open **Settings** on your phone", systemImage: "1.circle.fill")
                    Label("Tap **About phone** → **Build number** 7 times", systemImage: "2.circle.fill")
                    Label("Go back → **Developer Options**", systemImage: "3.circle.fill")
                    Label("Enable **USB Debugging**", systemImage: "4.circle.fill")
                    Label("Accept the prompt on your phone screen", systemImage: "5.circle.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 28)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.orange.opacity(0.2), lineWidth: 0.5)
                )
        )
    }
}
