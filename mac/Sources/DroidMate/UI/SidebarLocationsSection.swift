import AppKit
import SwiftUI

/// Favorites, fixed shortcuts, and recent paths for the file-browser sidebar.
struct SidebarLocationsSection: View {
    @ObservedObject var client: FileClient

    private struct Location: Identifiable, Hashable {
        var id: String { path }
        let title: String
        let path: String
        let icon: String
    }

    private let shortcuts: [Location] = [
        Location(title: "Files", path: "/", icon: "internaldrive"),
        Location(title: "Download", path: "Download", icon: "arrow.down.circle"),
        Location(title: "DCIM", path: "DCIM", icon: "camera"),
        Location(title: "Pictures", path: "Pictures", icon: "photo"),
        Location(title: "Documents", path: "Documents", icon: "doc.text"),
        Location(title: "Music", path: "Music", icon: "music.note"),
        Location(title: "Movies", path: "Movies", icon: "film"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            favoritesSection
            locationsSection
            recentPathsSection
        }
    }

    @ViewBuilder
    private var favoritesSection: some View {
        let pins = client.pinnedPaths()
        let _ = client.pinEpoch
        if !pins.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                sidebarSectionHeader("Favorites")
                    .padding(.bottom, 4)
                ForEach(pins, id: \.self) { path in
                    pathShortcutRow(
                        path: path,
                        icon: "star.fill",
                        iconTint: .yellow,
                        kind: .favorite
                    )
                }
            }
        }
    }

    private var locationsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sidebarSectionHeader("Locations")
                .padding(.bottom, 4)
            ForEach(shortcuts) { loc in
                locationRow(loc)
            }
        }
    }

    @ViewBuilder
    private var recentPathsSection: some View {
        let pinned = Set(client.pinnedPaths())
        let recent = client.recentPaths().filter { path in
            !shortcuts.contains(where: { $0.path == path }) && !pinned.contains(path)
        }
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                sidebarSectionHeader("Recent")
                    .padding(.bottom, 4)
                ForEach(recent, id: \.self) { path in
                    pathShortcutRow(
                        path: path,
                        icon: "clock.arrow.circlepath",
                        iconTint: .secondary,
                        kind: .recent
                    )
                }
            }
        }
    }

    private enum PathRowKind { case favorite, recent }

    private func pathShortcutRow(
        path: String,
        icon: String,
        iconTint: Color,
        kind: PathRowKind
    ) -> some View {
        let label = path == "/"
            ? String(localized: "Files")
            : (path.split(separator: "/").last.map(String.init) ?? path)
        let isActive = client.currentPath == path
            || (path != "/" && client.currentPath.hasPrefix(path + "/"))
        return Button {
            Task { await client.list(path: path) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(isActive ? Color.accentColor : iconTint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(label)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if path != "/" && path.contains("/") {
                        Text(path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, DM.Space.sm)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sidebarRowBackground(isActive: isActive)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
        .help(path)
        .contextMenu {
            Button {
                client.togglePinned(path)
            } label: {
                Label(
                    client.isPinned(path) ? "Unpin" : "Pin",
                    systemImage: client.isPinned(path) ? "star.slash" : "star"
                )
            }
            Button {
                copyDevicePath(path)
            } label: {
                Label("Copy Path", systemImage: "link")
            }
            switch kind {
            case .favorite:
                Button(role: .destructive) {
                    client.removePinned(path)
                } label: {
                    Label("Remove from Favorites", systemImage: "trash")
                }
            case .recent:
                Button {
                    client.removeRecentPath(path)
                } label: {
                    Label("Remove from Recent", systemImage: "clock.badge.xmark")
                }
                Button(role: .destructive) {
                    client.clearRecentPaths()
                } label: {
                    Label("Clear Recent", systemImage: "trash")
                }
            }
        }
    }

    private func locationRow(_ loc: Location) -> some View {
        let isActive = isActiveLocation(loc)
        return Button {
            Task { await client.list(path: loc.path) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: loc.icon)
                    .foregroundStyle(isActive ? Color.accentColor : Color.accentColor.opacity(0.85))
                    .frame(width: 18)
                Text(LocalizedStringKey(loc.title))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, DM.Space.sm)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sidebarRowBackground(isActive: isActive)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
        .contextMenu {
            Button {
                client.togglePinned(loc.path)
            } label: {
                Label(
                    client.isPinned(loc.path) ? "Unpin" : "Pin",
                    systemImage: client.isPinned(loc.path) ? "star.slash" : "star"
                )
            }
            Button {
                copyDevicePath(loc.path)
            } label: {
                Label("Copy Path", systemImage: "link")
            }
        }
    }

    private func isActiveLocation(_ loc: Location) -> Bool {
        if loc.path == "/" { return client.currentPath == "/" }
        return client.currentPath == loc.path || client.currentPath.hasPrefix(loc.path + "/")
    }

    private func copyDevicePath(_ path: String) {
        let abs = client.absoluteDevicePath(relative: path)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(abs, forType: .string)
    }
}
