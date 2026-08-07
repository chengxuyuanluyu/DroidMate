import SwiftUI

/// Clickable path bar. Each segment navigates to that folder.
/// Deep paths auto-scroll so the current folder stays fully visible
/// (not clipped by the rounded capsule on the right).
struct BreadcrumbView: View {
    @ObservedObject var client: FileClient
    let onNavigate: (String) -> Void

    /// Stable id for the trailing edge — more reliable than segment path
    /// when scrollTo runs before the last button finishes layout.
    private static let endAnchorID = "breadcrumb.end"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    Button {
                        onNavigate("/")
                    } label: {
                        Image(systemName: "internaldrive")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .dmHoverHighlight(cornerRadius: DM.Radius.sm)
                    .help("Device storage root")
                    .id("breadcrumb.root")

                    ForEach(Array(segments.enumerated()), id: \.element.id) { idx, seg in
                        chevron
                        Button {
                            onNavigate(seg.path)
                        } label: {
                            Text(seg.label)
                                .font(.callout.weight(idx == segments.count - 1 ? .semibold : .regular))
                                .lineLimit(1)
                                // Cap very long folder names so one segment can't
                                // dominate the bar; still fully scrollable.
                                .frame(maxWidth: 180, alignment: .leading)
                                .truncationMode(.middle)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                        }
                        .buttonStyle(BreadcrumbSegmentStyle(active: idx == segments.count - 1))
                        // Required for ScrollViewReader — ForEach's id: alone is
                        // not enough for proxy.scrollTo to find the view.
                        .id(seg.id)
                    }

                    // Invisible trailing anchor with a little breathing room so
                    // the active segment isn't flush against the capsule edge.
                    Color.clear
                        .frame(width: 8, height: 1)
                        .id(Self.endAnchorID)
                }
                .padding(.leading, 4)
                .padding(.trailing, 4)
                .padding(.vertical, 2)
            }
            .onAppear { scrollToCurrent(proxy) }
            .onChange(of: client.currentPath) { _, _ in scrollToCurrent(proxy) }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        // Wait one layout pass so the new segment ids exist, then pin the
        // trailing edge so the current folder is fully inside the capsule.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(Self.endAnchorID, anchor: .trailing)
            }
        }
    }

    private struct Segment: Identifiable, Equatable {
        /// Stable path identity — never UUID-per-body (that thrashed SwiftUI identity).
        var id: String { path }
        let label: String
        let path: String
    }

    private var segments: [Segment] {
        let parts = client.components(of: client.currentPath)
        var built = ""
        return parts.map { part in
            built = built.isEmpty ? part : "\(built)/\(part)"
            return Segment(label: part, path: built)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 1)
    }
}

private struct BreadcrumbSegmentStyle: ButtonStyle {
    let active: Bool
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: DM.Radius.sm, style: .continuous)
                    .fill(active
                          ? Color.accentColor.opacity(0.12)
                          : (hovered ? DM.hoverFill : Color.clear))
            )
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(DM.Motion.micro(reduceMotion: reduceMotion), value: configuration.isPressed)
            .onHover { hovered = $0 }
            .contentShape(Rectangle())
    }
}
