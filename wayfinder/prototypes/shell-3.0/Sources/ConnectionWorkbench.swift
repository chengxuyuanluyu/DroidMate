import SwiftUI

/// Flow A — full-page connection workbench (no ready session).
struct ConnectionWorkbench: View {
    @Bindable var state: PrototypeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            PrototypeBanner()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    situationalCards
                    recentSection
                }
                .padding(32)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("DroidMate", systemImage: "iphone.and.arrow.forward")
                .font(.largeTitle.weight(.semibold))
            Text("Connect a phone — USB or wireless. This is the cold-start shell.")
                .foregroundStyle(.secondary)
        }
    }

    private var situationalCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suggested")
                .font(.headline)
            HStack(alignment: .top, spacing: 16) {
                actionCard(
                    title: "Use USB phone",
                    subtitle: "Pixel 8 is ready",
                    systemImage: "cable.connector",
                    accent: true
                ) {
                    if let d = state.devices.first(where: { $0.online }) {
                        withAnimation(ProtoMotion.macro(reduceMotion: reduceMotion)) {
                            state.connect(to: d)
                        }
                    }
                }
                actionCard(
                    title: "Add wireless phone",
                    subtitle: "Pairing wizard (stub)",
                    systemImage: "wifi",
                    accent: false
                ) {
                    state.statusNote = "Wizard stub — not implemented in prototype"
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("My phones")
                .font(.headline)
            ForEach(state.devices) { device in
                Button {
                    withAnimation(ProtoMotion.macro(reduceMotion: reduceMotion)) {
                        state.connect(to: device)
                    }
                } label: {
                    HStack {
                        Image(systemName: device.online ? "iphone" : "iphone.slash")
                            .foregroundStyle(device.online ? Color.accentColor : .secondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.body.weight(.medium))
                            Text(device.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func actionCard(
        title: String,
        subtitle: String,
        systemImage: String,
        accent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(accent ? Color.accentColor : .secondary)
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(accent ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
