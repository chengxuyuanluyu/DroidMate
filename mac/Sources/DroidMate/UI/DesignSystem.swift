import AppKit
import SwiftUI

/// Visual language for DroidMate — Finder-native utility craft with a quiet brand accent.
///
/// 3.0 contracts: `docs/3.0/visual-language.md`, `docs/3.0/motion-language.md`.
enum DM {
    // MARK: Spacing (4pt grid)

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
    }

    // MARK: Corner radii

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
    }

    // MARK: Appearance (docs/3.0 visual language)

    /// User preference: Follow System (default), Light, or Dark.
    enum AppearancePreference: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        static let storageKey = "ui.appearance"

        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .system: return "Follow System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        /// `nil` = follow system (SwiftUI `preferredColorScheme(nil)`).
        var preferredColorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }

        static var current: AppearancePreference {
            let raw = UserDefaults.standard.string(forKey: storageKey) ?? AppearancePreference.system.rawValue
            return AppearancePreference(rawValue: raw) ?? .system
        }
    }

    /// Effective dark mode for adaptive fills (respects app appearance override).
    static var isDark: Bool {
        switch AppearancePreference.current {
        case .light: return false
        case .dark: return true
        case .system:
            return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        }
    }

    // MARK: Brand (from AppIcon gradient — use sparingly)

    enum Brand {
        static let blue = Color(.sRGB, red: 0.30, green: 0.40, blue: 0.96, opacity: 1)
        static let purple = Color(.sRGB, red: 0.52, green: 0.28, blue: 0.88, opacity: 1)
        /// Slightly brighter blue for icons on dark backgrounds.
        static let blueBright = Color(.sRGB, red: 0.45, green: 0.55, blue: 1.0, opacity: 1)

        static var gradient: LinearGradient {
            LinearGradient(
                colors: [blue, purple],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        static var softFill: LinearGradient {
            let dark = DM.isDark
            return LinearGradient(
                colors: dark
                    ? [blue.opacity(0.28), purple.opacity(0.18)]
                    : [blue.opacity(0.14), purple.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        static var markShadow: Color {
            DM.isDark ? purple.opacity(0.45) : purple.opacity(0.28)
        }

        static var iconOnDark: Color {
            DM.isDark ? blueBright : blue
        }
    }

    // MARK: Chrome heights

    enum Chrome {
        static let pathBarHeight: CGFloat = 40
        static let statusBarHeight: CGFloat = 28
        static let sidebarRowMin: CGFloat = 28
    }

    // MARK: Surfaces (light / dark adaptive)

    /// Nested control wells (search field, breadcrumb tray, chips).
    static var panelFill: Color {
        isDark
            ? Color.white.opacity(0.07)
            : Color(nsColor: .controlBackgroundColor).opacity(0.72)
    }

    /// Very light fill for idle chrome.
    static var subtleFill: Color {
        isDark ? Color.white.opacity(0.05) : Color(nsColor: .separatorColor).opacity(0.32)
    }

    /// Hover / press fill.
    static var hoverFill: Color {
        isDark ? Color.white.opacity(0.10) : Color(nsColor: .separatorColor).opacity(0.48)
    }

    /// 0.5pt hairline borders.
    static var cardStroke: Color {
        isDark ? Color.white.opacity(0.12) : Color(nsColor: .separatorColor).opacity(0.42)
    }

    /// Soft selection fill (list + grid share this — never solid system blue).
    static func selectionFill(active: Bool) -> Color {
        guard active else { return .clear }
        return Color.accentColor.opacity(isDark ? 0.38 : 0.16)
    }

    static func selectionStroke(active: Bool) -> Color {
        guard active else { return .clear }
        return Color.accentColor.opacity(isDark ? 0.55 : 0.38)
    }

    /// Unified selected / hover chrome for file list rows and grid tiles.
    enum SelectionChrome {
        static func fill(selected: Bool, hovered: Bool) -> Color {
            if selected { return DM.selectionFill(active: true) }
            if hovered { return DM.subtleFill }
            return .clear
        }

        static func stroke(selected: Bool, hovered: Bool) -> Color {
            if selected { return DM.selectionStroke(active: true) }
            if hovered { return DM.cardStroke }
            return .clear
        }

        static func lineWidth(selected: Bool) -> CGFloat {
            selected ? 1.25 : 0.5
        }
    }

    // MARK: Motion (docs/3.0/motion-language.md)

    /// Semantic motion bands for product chrome. Prefer these over ad-hoc springs.
    ///
    /// - **micro** — hover / press (~0–120ms band)
    /// - **meso** — panels, inspector, sheets (~200–350ms)
    /// - **macro** — rare workspace transitions (~350–500ms)
    /// - **selection** / **progress** — intentionally unanimated (P1 / P4)
    enum Motion {
        /// Hover / press (critically damped — no bounce).
        static let micro = Animation.spring(response: 0.22, dampingFraction: 1.0)
        /// Panels, inspector, transfer sheet, mirror control present/dismiss.
        static let meso = Animation.spring(response: 0.32, dampingFraction: 1.0)
        /// Connection workbench ↔ session (rare).
        static let macro = Animation.spring(response: 0.42, dampingFraction: 1.0)
        /// Opacity path for Reduce Motion or soft fades.
        static let crossfade = Animation.easeOut(duration: 0.16)
        /// Reduce Motion substitute for meso/macro displacement.
        static let reduced = Animation.easeOut(duration: 0.12)

        /// Selection wash — same-frame; never spring (performance budget P1).
        static let selection: Animation? = nil
        /// Determinate transfer progress — no spring (P4).
        static let progress: Animation? = nil

        /// Rare delight (e.g. completion checkmark). Prefer meso for chrome.
        static let pop = Animation.spring(response: 0.28, dampingFraction: 0.82)

        /// Panel/sheet band with Reduce Motion dual path.
        static func meso(reduceMotion: Bool) -> Animation? {
            reduceMotion ? reduced : meso
        }

        /// Workspace band with Reduce Motion dual path.
        static func macro(reduceMotion: Bool) -> Animation? {
            reduceMotion ? reduced : macro
        }

        /// Micro interactions: off or crossfade when Reduce Motion is on.
        static func micro(reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : micro
        }
    }
}

// MARK: - Shared selection background shape

/// Soft accent wash + stroke used by both list rows and grid tiles.
/// Call sites must not wrap selection changes in spring animations (use `DM.Motion.selection`).
struct DMSelectionBackground: View {
    let selected: Bool
    var hovered: Bool = false
    var cornerRadius: CGFloat = DM.Radius.md

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(DM.SelectionChrome.fill(selected: selected, hovered: hovered))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        DM.SelectionChrome.stroke(selected: selected, hovered: hovered),
                        lineWidth: DM.SelectionChrome.lineWidth(selected: selected)
                    )
            )
            // P1: selection chrome never inherits ambient springs.
            .animation(DM.Motion.selection, value: selected)
    }
}

// MARK: - Shared chrome pieces

/// Soft brand mark used on connection / onboarding / empty states.
/// Uses the designed AppIcon when available; falls back to SF Symbol disc.
struct BrandMark: View {
    var size: CGFloat = 56
    var systemImage: String = "iphone.gen3.radiowaves.left.and.right"
    /// When true, show the full squircle app icon (About / Settings).
    /// When false, use a circular clip for compact chrome.
    var useAppIcon: Bool = true

    var body: some View {
        Group {
            if useAppIcon {
                Image(nsImage: AppIcon.brandNSImage(size: size * 2))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.223, style: .continuous))
                    .shadow(color: DM.Brand.markShadow, radius: size * 0.14, y: size * 0.06)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(DM.Brand.gradient, in: Circle())
                    .shadow(color: DM.Brand.markShadow, radius: size * 0.18, y: size * 0.07)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Grouped panel used on the connection method column and similar cards.
struct SurfaceCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(DM.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DM.Radius.lg, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DM.Radius.lg, style: .continuous)
                    .strokeBorder(DM.cardStroke, lineWidth: 0.5)
            )
    }
}

/// Section label for sidebars — small caps tracking, secondary.
struct SectionLabel: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
            .padding(.horizontal, DM.Space.sm)
    }
}

// MARK: - View helpers

extension View {
    /// Continuous corner radius card with optional material.
    func dmCard(padding: CGFloat = DM.Space.md, material: Bool = true) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: DM.Radius.lg, style: .continuous)
                    .fill(material ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(DM.panelFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DM.Radius.lg, style: .continuous)
                    .strokeBorder(DM.cardStroke, lineWidth: 0.5)
            )
    }

    func dmHoverHighlight(cornerRadius: CGFloat = DM.Radius.md) -> some View {
        modifier(HoverHighlightModifier(cornerRadius: cornerRadius))
    }
}

private struct HoverHighlightModifier: ViewModifier {
    let cornerRadius: CGFloat
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(hovered ? DM.hoverFill : Color.clear)
            )
            .onHover { hovered = $0 }
    }
}
