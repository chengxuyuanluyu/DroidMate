import SwiftUI

/// Soft accent wash — selection must use this with NO animation (P1).
struct SoftSelectionBackground: View {
    let selected: Bool
    var hovered: Bool = false

    var body: some View {
        let fill: Color = {
            if selected { return Color.accentColor.opacity(0.18) }
            if hovered { return Color.primary.opacity(0.05) }
            return .clear
        }()
        let stroke: Color = {
            if selected { return Color.accentColor.opacity(0.4) }
            return .clear
        }()
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(stroke, lineWidth: selected ? 1.25 : 0)
            )
    }
}

struct PrototypeBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("PROTOTYPE — throwaway Shell 3.0 · fixture data only")
                .font(.caption.weight(.semibold))
            Spacer()
            Text("docs/3.0 · ticket 10")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }
}
