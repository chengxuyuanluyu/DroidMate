import SwiftUI

/// Shared sidebar row background: soft selection (not full neon bar), hover lift.
/// Uses DM adaptive fills so dark mode keeps contrast without washed-out grays.
struct SidebarRowBackground: ViewModifier {
    let isActive: Bool
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DM.Radius.md, style: .continuous)
                    .fill(isActive ? DM.selectionFill(active: true) : (hovered ? DM.hoverFill : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DM.Radius.md, style: .continuous)
                    .strokeBorder(DM.selectionStroke(active: isActive), lineWidth: 0.5)
            )
            .onHover { hovered = $0 }
            .animation(AppSpring.crossfade, value: hovered)
            .animation(AppSpring.snappy, value: isActive)
    }
}

extension View {
    func sidebarRowBackground(isActive: Bool) -> some View {
        modifier(SidebarRowBackground(isActive: isActive))
    }
}

@MainActor
func sidebarSectionHeader(_ title: LocalizedStringKey) -> some View {
    SectionLabel(title: title)
}
