import SwiftUI

/// Monospaced breadcrumb path bar. Each segment is clickable; taps list the
/// parent path. Middle-truncates when the bar overflows.
struct BreadcrumbView: View {
    @ObservedObject var client: FileClient
    let onNavigate: (String) -> Void

    var body: some View {
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

                ForEach(Array(segments.enumerated()), id: \.element.id) { idx, seg in
                    chevron
                    Button {
                        onNavigate(seg.path)
                    } label: {
                        Text(seg.label)
                            .font(.callout.weight(idx == segments.count - 1 ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(BreadcrumbSegmentStyle(active: idx == segments.count - 1))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }

    private struct Segment: Identifiable {
        let id = UUID()
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
            .animation(reduceMotion ? nil : AppSpring.snappy, value: configuration.isPressed)
            .onHover { hovered = $0 }
            .contentShape(Rectangle())
    }
}
