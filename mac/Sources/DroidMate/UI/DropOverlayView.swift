import SwiftUI

/// Materialises (blur + scale together) when a drag hovers over the file area.
/// Symmetric enter/exit. Set `isTargeted` from the parent's `.onDrop(...)` via
/// `isTargeted` binding.
struct DropOverlayView: View {
    let isTargeted: Bool
    var path: String = "/"
    /// Optional count of items about to land (from DropDelegate proposal).
    var itemCount: Int? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: DM.Space.md) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 40, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DM.Brand.gradient)
            Text(titleText)
                .font(.title3.weight(.semibold))
            Text(path == "/"
                  ? String(localized: "Upload to device storage — files and folders (empty folders included)")
                  : String(localized: "Upload to \(path) — files and folders (empty folders included)"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DM.Space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DM.Radius.xl, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: DM.Radius.xl, style: .continuous)
                        .strokeBorder(DM.Brand.iconOnDark.opacity(DM.isDark ? 0.85 : 0.7),
                                      style: StrokeStyle(lineWidth: 2, dash: [10, 6]))
                )
        )
        .padding(DM.Space.md)
        .scaleEffect(isTargeted && !reduceMotion ? 0.99 : 1)
        .opacity(isTargeted ? 1 : 0)
        .allowsHitTesting(false)
        .animation(reduceMotion ? AppSpring.crossfade : AppSpring.standard, value: isTargeted)
    }

    private var titleText: String {
        if let itemCount, itemCount > 1 {
            return String(localized: "Drop \(itemCount) items to upload")
        }
        if itemCount == 1 {
            return String(localized: "Drop to upload")
        }
        return String(localized: "Drop to upload")
    }
}
