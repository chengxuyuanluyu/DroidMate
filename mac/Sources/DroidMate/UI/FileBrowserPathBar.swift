import SwiftUI

/// Navigation + breadcrumb + pin + search + refresh strip above the file list.
struct FileBrowserPathBar: View {
    @ObservedObject var client: FileClient
    @FocusState.Binding var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DM.Space.sm) {
            HStack(spacing: 2) {
                Button {
                    Task { await client.goBack() }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(ToolbarButtonStyle())
                .disabled(!client.canGoBack)
                .help("Back")

                Button {
                    Task { await client.goForward() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(ToolbarButtonStyle())
                .disabled(!client.canGoForward)
                .help("Forward")
            }

            BreadcrumbView(client: client) { path in
                Task { await client.list(path: path) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DM.Space.xs)
            .padding(.vertical, 3)
            // Clip so a long path can't paint past the capsule edge into the
            // star button (the previous "half letter" bleed).
            .background(
                RoundedRectangle(cornerRadius: DM.Radius.sm, style: .continuous)
                    .fill(DM.panelFill)
            )
            .clipShape(RoundedRectangle(cornerRadius: DM.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DM.Radius.sm, style: .continuous)
                    .strokeBorder(DM.cardStroke, lineWidth: 0.5)
            )

            Button {
                client.togglePinned(client.currentPath)
            } label: {
                Image(systemName: client.isPinned(client.currentPath) ? "star.fill" : "star")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(client.isPinned(client.currentPath)
                                     ? Color(.sRGB, red: 0.95, green: 0.72, blue: 0.15, opacity: 1)
                                     : Color.secondary)
            }
            .buttonStyle(ToolbarButtonStyle())
            .help(client.isPinned(client.currentPath)
                  ? String(localized: "Unpin this folder")
                  : String(localized: "Pin this folder"))

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                TextField("Search", text: $client.searchQuery)
                    .textFieldStyle(.plain)
                    .controlSize(.small)
                    .frame(width: searchFocused || !client.searchQuery.isEmpty ? 168 : 124)
                    .focused($searchFocused)
                    .help(String(localized: "Search current folder only (⌘F)"))
                if !client.searchQuery.isEmpty {
                    Button {
                        client.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, DM.Space.sm)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DM.Radius.sm, style: .continuous)
                    .fill(DM.panelFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DM.Radius.sm, style: .continuous)
                    .strokeBorder(
                        searchFocused ? Color.accentColor.opacity(0.65) : DM.cardStroke,
                        lineWidth: searchFocused ? 1.25 : 0.5
                    )
            )
            .animation(reduceMotion ? nil : AppSpring.crossfade, value: searchFocused)

            Button {
                Task { await client.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(ToolbarButtonStyle())
            .disabled(client.isTransferring)
            .help("Refresh (⌘R)")
        }
        .padding(.horizontal, DM.Space.md)
        .padding(.vertical, DM.Space.sm)
        .frame(minHeight: DM.Chrome.pathBarHeight)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DM.cardStroke)
                .frame(height: 0.5)
        }
    }
}
