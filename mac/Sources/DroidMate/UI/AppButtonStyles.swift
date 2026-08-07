import SwiftUI

/// Shared speed formatter used by StatusBarView and TransferQueueView.
func formatTransferSpeed(_ mbps: Double) -> String {
    if mbps >= 1 {
        return String(format: "%.1f MB/s", mbps)
    }
    return String(format: "%.0f KB/s", mbps * 1000)
}

/// Compatibility aliases for pre-3.0 call sites.
/// Prefer `DM.Motion` for new code (docs/3.0/motion-language.md).
enum AppSpring {
    /// Sheet / panel settle → `DM.Motion.meso`
    static var standard: Animation { DM.Motion.meso }
    /// Press / hover / toggle → `DM.Motion.micro`
    static var snappy: Animation { DM.Motion.micro }
    /// Rare delight (completion checkmarks)
    static var pop: Animation { DM.Motion.pop }
    static var crossfade: Animation { DM.Motion.crossfade }
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
            .animation(DM.Motion.micro(reduceMotion: reduceMotion) ?? DM.Motion.crossfade, value: configuration.isPressed)
            .animation(DM.Motion.micro(reduceMotion: reduceMotion), value: hovered)
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
            .animation(DM.Motion.micro(reduceMotion: reduceMotion) ?? DM.Motion.crossfade, value: configuration.isPressed)
    }
}

/// Connection-page device row / primary list row press language.
struct QuietRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.92 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
            .animation(DM.Motion.micro(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}
