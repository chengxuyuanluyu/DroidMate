import SwiftUI

/// Shared speed formatter used by StatusBarView and TransferQueueView.
func formatTransferSpeed(_ mbps: Double) -> String {
    if mbps >= 1 {
        return String(format: "%.1f MB/s", mbps)
    }
    return String(format: "%.0f KB/s", mbps * 1000)
}

/// Spring tokens — critically damped by default (Apple-style, no bounce on chrome).
enum AppSpring {
    /// Sheet / panel settle
    static let standard = SwiftUI.Animation.spring(response: 0.32, dampingFraction: 1.0)
    /// Press / hover / toggle
    static let snappy = SwiftUI.Animation.spring(response: 0.22, dampingFraction: 1.0)
    /// Rare delight (completion checkmarks)
    static let pop = SwiftUI.Animation.spring(response: 0.28, dampingFraction: 0.82)
    static let crossfade = SwiftUI.Animation.easeOut(duration: 0.16)
}

/// Toolbar / icon button — highlight on pointer-down, scale 0.97 (Emil / Apple press).
struct ToolbarButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, DM.Space.sm)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DM.Radius.sm, style: .continuous)
                    .fill(configuration.isPressed
                          ? DM.hoverFill
                          : (hovered ? DM.subtleFill : Color.clear))
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? AppSpring.crossfade : AppSpring.snappy, value: configuration.isPressed)
            .animation(reduceMotion ? nil : AppSpring.crossfade, value: hovered)
            .onHover { hovered = $0 }
            .contentShape(Rectangle())
    }
}

/// Sidebar row: press scale only (selection fill lives on the row background).
struct SidebarRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? AppSpring.crossfade : AppSpring.snappy, value: configuration.isPressed)
    }
}

/// Connection-page device row / primary list row press language.
struct QuietRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.92 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
            .animation(reduceMotion ? nil : AppSpring.snappy, value: configuration.isPressed)
    }
}
