import SwiftUI

/// Bottom status bar: item count, transfer progress with name, or a
/// spring-pop checkmark that auto-dismisses.
///
/// Observes `transfers` separately so progress ticks do not rebuild the
/// file list (which only observes `client`).
struct StatusBarView: View {
    @ObservedObject var client: FileClient
    @ObservedObject var transfers: TransferEngine
    var selectionCount: Int = 0
    var selectionTotalSize: Int64 = 0
    /// Open the transfer queue sheet (click progress / completion).
    var onShowTransfers: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Text(itemCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if client.canPaste {
                clipboardIndicator
            }

            Spacer(minLength: 8)

            if transfers.isTransferring {
                transferIndicator
                    .contentShape(Rectangle())
                    .onTapGesture { onShowTransfers?() }
                    .help(String(localized: "Show transfer queue"))
            } else if let done = transfers.lastCompletedTransfer {
                completionIndicator(done)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Prefer reveal destination; fall back to transfer queue.
                        if let url = done.destinationURL,
                           FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            onShowTransfers?()
                        }
                    }
                    .help(done.destinationURL != nil
                          ? String(localized: "Show in Finder — open transfer queue from the toolbar")
                          : String(localized: "Show transfer queue"))
            }

            // Wave 4: always-available first-class entry (summary bar, not the only UI).
            transferQueueButton
        }
        .padding(.horizontal, DM.Space.md)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: DM.Chrome.statusBarHeight)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DM.cardStroke)
                .frame(height: 0.5)
        }
        .animation(DM.Motion.meso(reduceMotion: reduceMotion), value: transfers.isTransferring)
        .animation(DM.Motion.meso(reduceMotion: reduceMotion), value: transfers.lastCompletedTransfer)
        .task(id: transfers.lastCompletedTransfer) {
            guard transfers.lastCompletedTransfer != nil else { return }
            // Long enough to click Show / notice completion after multi-file work.
            try? await Task.sleep(for: .seconds(3.5))
            if !Task.isCancelled {
                withAnimation(DM.Motion.meso(reduceMotion: reduceMotion)) {
                    transfers.lastCompletedTransfer = nil
                }
            }
        }
        .onChange(of: transfers.activeTransferCount) { _, count in
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
    }

    private var itemCountLabel: String {
        let n = client.visibleEntries.count
        let total = client.entries.count
        if selectionCount > 0 {
            let size = ByteCountFormatter.string(fromByteCount: selectionTotalSize, countStyle: .file)
            return String(localized: "\(selectionCount) of \(n) selected — \(size)")
        }
        // Filtered / searching: show subset vs full folder size.
        if n != total, total > 0 {
            return String(localized: "\(n) of \(total) items")
        }
        if total >= FileClient.largeFolderThreshold {
            if n == 1 {
                return String(localized: "1 item · large folder")
            }
            return String(localized: "\(n) items · large folder")
        }
        if n == 1 {
            return String(localized: "1 item")
        }
        return String(localized: "\(n) items")
    }

    private var transferQueueButton: some View {
        let active = transfers.activeTransferCount
        let hasHistory = !transfers.transferHistory.isEmpty
        return Button {
            onShowTransfers?()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: active > 0
                      ? "arrow.left.arrow.right.circle.fill"
                      : "arrow.left.arrow.right.circle")
                    .font(.caption)
                if active > 0 {
                    Text("\(active)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                } else if hasHistory {
                    Text(String(localized: "Queue"))
                        .font(.caption2)
                }
            }
            .foregroundStyle(active > 0 ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(DM.panelFill))
            .overlay(Capsule().strokeBorder(DM.cardStroke, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(String(localized: "Transfer Queue"))
        .accessibilityLabel(String(localized: "Transfer Queue"))
    }

    private var transferIndicator: some View {
        HStack(spacing: 8) {
            ProgressView(value: transfers.transferProgress)
                .progressViewStyle(.linear)
                .frame(width: 120)
                .controlSize(.small)
                // P4 / DM.Motion.progress — no spring on determinate transfer UI.
                .animation(DM.Motion.progress, value: transfers.transferProgress)
            Text("\(Int(transfers.transferProgress * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            Text(transfers.transferSpeedMBps > 0.01
                  ? formatTransferSpeed(transfers.transferSpeedMBps)
                  : "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .trailing)
            Text({
                if let eta = transfers.estimatedRemainingSeconds, eta.isFinite, eta >= 1, eta < 24 * 3600 {
                    return etaLabel(eta)
                }
                return " "
            }())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .trailing)
            if let name = transfers.activeTransferName {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
            }
        }
        // Fixed-ish chrome so speed/ETA appearing doesn't shove neighbors.
        .frame(minHeight: 16)
    }

    private func etaLabel(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return String(localized: "~\(s)s") }
        let m = s / 60
        let r = s % 60
        if m < 60 { return String(format: "~%d:%02d", m, r) }
        return String(format: "~%dh", m / 60)
    }

    private func completionIndicator(_ done: CompletedTransfer) -> some View {
        let size = ByteCountFormatter.string(fromByteCount: done.bytes, countStyle: .file)
        let label: String = {
            if done.direction == .download {
                return String(localized: "Copied \(size)")
            }
            return String(localized: "Uploaded \(size)")
        }()
        return HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let url = done.destinationURL {
                Button("Show") {
                    if FileManager.default.fileExists(atPath: url.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        let parent = url.deletingLastPathComponent()
                        NSWorkspace.shared.open(parent)
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Show in Finder")
            }
        }
        .transition(reduceMotion
                    ? .opacity
                    : .scale(scale: 0.7).combined(with: .opacity))
    }

    private var clipboardIndicator: some View {
        let count = client.clipboardEntries.count
        let modeHelp = client.clipboardMode == .cut
            ? String(localized: "\(count) items cut — ⌘V to paste. Click to clear.")
            : String(localized: "\(count) items copied — ⌘V to paste. Click to clear.")
        return HStack(spacing: 3) {
            Image(systemName: client.clipboardMode == .cut
                  ? "scissors"
                  : "doc.on.doc")
                .font(.caption2)
            Text("\(count)")
                .font(.caption2.monospacedDigit())
            Text(client.clipboardMode == .cut
                  ? String(localized: "Cut")
                  : String(localized: "Copied"))
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(DM.panelFill))
        .overlay(Capsule().strokeBorder(DM.cardStroke, lineWidth: 0.5))
        .contentShape(Capsule())
        .onTapGesture {
            client.clearClipboard()
        }
        .help(modeHelp)
        .transition(.opacity)
    }
}
