import SwiftUI

/// Inline slim banner for client errors. Slides in from the top with a soft
/// spring; dismissable; no modal alerts.
struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, DM.Space.md)
        .padding(.vertical, DM.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: DM.Radius.md, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: DM.Radius.md, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.4), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, DM.Space.md)
        .padding(.top, DM.Space.sm)
        .transition(reduceMotion
                    ? .opacity
                    : .move(edge: .top).combined(with: .opacity))
    }
}
