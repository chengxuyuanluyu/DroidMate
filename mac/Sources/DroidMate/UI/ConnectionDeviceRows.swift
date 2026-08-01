import SwiftUI

/// Ready-device row on the connection workspace.
///
/// Primary action = connect / open session. Wi-Fi (or dual-link) groups and
/// in-use USB sessions also expose **Disconnect**.
struct ConnectionDeviceRow: View {
    /// Friendly title (model when known).
    let title: String
    /// Serial / endpoint detail under the title.
    let detail: String
    /// SF Symbol for the leading glyph.
    let systemImage: String
    /// Link badge text: "USB", "Wi-Fi", "USB · Wi-Fi".
    let linkLabel: String
    let isSelected: Bool
    let isRowConnecting: Bool
    let isConnected: Bool
    let isDisabled: Bool
    /// Stage text while connecting (optional).
    var connectingStage: String? = nil
    let onConnect: () -> Void
    /// When set, shows a disconnect control (wireless/dual always; USB only when in session).
    var onDisconnect: (() -> Void)? = nil
    /// True when disconnect should appear even without a session (wireless present).
    var alwaysShowDisconnect: Bool = false

    private var showsDisconnect: Bool {
        onDisconnect != nil && (alwaysShowDisconnect || isConnected)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onConnect) {
                HStack(spacing: DM.Space.md) {
                    ZStack {
                        Circle()
                            .fill(DM.Brand.softFill)
                            .frame(width: 36, height: 36)
                        Image(systemName: systemImage)
                            .font(.body.weight(.medium))
                            .foregroundStyle(DM.Brand.iconOnDark)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(titleLooksLikeSerial ? .body.monospaced() : .body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(isConnected ? .green : .secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if isRowConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(isConnected ? String(localized: "Open") : String(localized: "Connect"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isConnected ? Color.green : Color.accentColor)
                        Image(systemName: isConnected ? "checkmark.circle.fill" : "chevron.right")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(isConnected ? Color.green : Color.secondary)
                    }
                }
                .padding(.leading, DM.Space.md)
                .padding(.vertical, DM.Space.md)
                .padding(.trailing, showsDisconnect ? 4 : DM.Space.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(QuietRowButtonStyle())
            .disabled(isDisabled)
            .help(isConnected
                  ? String(localized: "Switch to this device in DroidMate")
                  : String(localized: "Start a DroidMate session"))

            if showsDisconnect, let onDisconnect {
                Button(role: .destructive, action: onDisconnect) {
                    Text(String(localized: "Disconnect"))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isDisabled || isRowConnecting)
                .help(alwaysShowDisconnect
                      ? String(localized: "Drop wireless adb and any DroidMate session")
                      : String(localized: "End DroidMate session for this USB device"))
                .padding(.trailing, DM.Space.md)
            }
        }
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
    }

    private var titleLooksLikeSerial: Bool {
        title.contains(":") || title.count > 14 && title.allSatisfy({ $0.isHexDigit || $0 == ":" })
    }

    private var subtitle: String {
        if isRowConnecting {
            if let connectingStage, !connectingStage.isEmpty {
                return connectingStage
            }
            return String(localized: "Connecting…")
        }
        if isConnected {
            return String(localized: "In use · \(linkLabel)")
        }
        // Show link type; append detail when it adds info beyond the title.
        if detail != title, !detail.isEmpty, detail != "device" {
            return "\(linkLabel) · \(detail)"
        }
        return linkLabel
    }
}

/// Unauthorized / offline adb device with optional setup guide.
struct ConnectionUnauthorizedRow: View {
    let device: AdbBridge.DeviceInfo
    var title: String? = nil
    @Binding var showSetupGuide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title ?? device.serial)
                        .font((title == nil) ? .callout.monospaced() : .callout.weight(.medium))
                    if let title, title != device.serial {
                        Text(device.serial)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text(device.state == "unauthorized"
                          ? String(localized: "USB debugging required")
                          : device.state.capitalized)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button(showSetupGuide ? String(localized: "Hide") : String(localized: "Setup Guide")) {
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
