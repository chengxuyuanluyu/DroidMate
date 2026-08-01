import AppKit
import SwiftUI

struct TransferQueueView: View {
    @ObservedObject var client: FileClient
    /// Observed separately so progress updates don't rebuild FileBrowserView.
    @ObservedObject var transfers: TransferEngine

    var body: some View {
        VStack(spacing: 0) {
            if transfers.isTransferring {
                batchSummaryBar
                Divider()
            }

            if transfers.transfers.isEmpty && transfers.transferHistory.isEmpty {
                VStack(spacing: DM.Space.lg) {
                    ZStack {
                        Circle()
                            .fill(DM.Brand.softFill)
                            .frame(width: 72, height: 72)
                        Image(systemName: "arrow.up.arrow.down.circle")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(DM.Brand.iconOnDark)
                    }
                    Text("No Transfers")
                        .font(.title3.weight(.semibold))
                    Text("Active and completed transfers appear here.\nDownloads resume from partials; uploads restart from the beginning.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(DM.Space.xxl)
            } else {
                List {
                    if !transfers.transfers.isEmpty {
                        Section {
                            ForEach(transfers.transfers) { item in
                                ActiveTransferRow(item: item) {
                                    client.cancelTransfer(item.id)
                                }
                            }
                        } header: {
                            SectionLabel(title: "Active")
                                .textCase(nil)
                        }
                    }
                    if !transfers.transferHistory.isEmpty {
                        Section {
                            ForEach(transfers.transferHistory) { record in
                                HistoryRow(
                                    record: record,
                                    onRetry: {
                                        Task { _ = await client.retryTransfer(record) }
                                    },
                                    onReveal: {
                                        reveal(record)
                                    }
                                )
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    reveal(record)
                                }
                            }
                        } header: {
                            SectionLabel(title: "History")
                                .textCase(nil)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 500, minHeight: 300, idealHeight: 440)
        .navigationTitle("Transfers")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if retryableCount > 0 {
                    Button("Retry (\(retryableCount))") {
                        retryAllRetryable()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Retry failed and paused transfers. Downloads resume; uploads restart.")
                }
                if !transfers.transfers.isEmpty {
                    Button("Pause All") {
                        client.pauseAllTransfers()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Stop active transfers. Downloads keep partials; uploads restart.")
                }
                if transfers.transferHistory.contains(where: { $0.status == .completed }) {
                    Button("Clear Completed") {
                        transfers.clearCompletedHistory()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Remove successful history rows; keep failed/paused for Retry")
                }
                if !transfers.transferHistory.isEmpty {
                    Button("Clear All") {
                        transfers.clearHistory()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Remove entire transfer history")
                }
            }
        }
    }

    private var retryableCount: Int {
        transfers.transferHistory.filter(\.canRetry).count
    }

    private func retryAllRetryable() {
        let items = transfers.transferHistory.filter(\.canRetry)
        Task {
            for record in items {
                _ = await client.retryTransfer(record)
            }
        }
    }

    private var batchSummaryBar: some View {
        HStack(spacing: DM.Space.md) {
            ProgressView(value: transfers.transferProgress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 220)
                .tint(DM.Brand.iconOnDark)
            Text("\(Int(transfers.transferProgress * 100))%")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            if transfers.batchTotalCount > 1 {
                Text(String(localized: "\(transfers.batchCompletedCount)/\(transfers.batchTotalCount) files"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(DM.panelFill))
            }
            if let name = transfers.activeTransferName {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
            }
            if transfers.transferSpeedMBps > 0.01 {
                Text(formatTransferSpeed(transfers.transferSpeedMBps))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if let eta = transfers.estimatedRemainingSeconds, eta.isFinite, eta > 0, eta < 24 * 3600 {
                // Bind ETA text first so localization key is cleanly "~%@ left".
                let etaText = formatETA(eta)
                Text(String(localized: "~\(etaText) left"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if !transfers.transfers.isEmpty {
                Button("Pause All") { client.pauseAllTransfers() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, DM.Space.lg)
        .padding(.vertical, DM.Space.md)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DM.cardStroke).frame(height: 0.5)
        }
    }

    private func reveal(_ record: TransferRecord) {
        // Downloads: show destination file. Uploads: show local source file.
        let url = record.destinationURL
        guard let url else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let parent = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path) {
                NSWorkspace.shared.open(parent)
            }
        }
    }

    private func formatETA(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return String(localized: "\(s)s") }
        let m = s / 60
        let r = s % 60
        if m < 60 { return String(format: "%d:%02d", m, r) }
        let h = m / 60
        let rm = m % 60
        return String(format: "%d:%02d:%02d", h, rm, r)
    }
}

private struct ActiveTransferRow: View {
    let item: TransferItem
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.direction == .download ? "arrow.down.doc" : "arrow.up.doc")
                .font(.callout)
                .foregroundStyle(item.direction == .download ? Color.blue : Color.green)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressView(value: item.progress)
                    .controlSize(.small)
                if item.bytesTotal > 0 {
                    Text("\(byteString(item.bytesDone)) / \(byteString(item.bytesTotal))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(item.progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.secondary)
                if item.speedMBps > 0.01 {
                    Text(formatTransferSpeed(item.speedMBps))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                }
            }
            .frame(width: 72, alignment: .trailing)

            Button(action: onCancel) {
                Image(systemName: item.canCancel ? "pause.circle.fill" : "hourglass.circle.fill")
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!item.canCancel)
            .help(!item.canCancel
                ? "Finishing upload — the destination is being committed"
                : (item.direction == .download
                    ? "Pause (keeps partial for resume)"
                    : "Pause (upload restarts from the beginning)"))
        }
        .padding(.vertical, 2)
    }

    private func byteString(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

private struct HistoryRow: View {
    let record: TransferRecord
    let onRetry: () -> Void
    let onReveal: () -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(statusLabel)
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                    Text(Self.relativeFormatter.localizedString(for: record.timestamp, relativeTo: Date()))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let err = record.errorMessage, record.status != .completed {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(Color.red)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 4)

            Text(ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.secondary)

            if record.destinationURL != nil {
                Button(action: onReveal) {
                    Image(systemName: "folder")
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .help(record.direction == .download ? "Show in Finder" : "Show source in Finder")
            }

            if record.canRetry {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(record.status == .cancelled ? "Resume" : "Retry")
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if record.destinationURL != nil {
                Button(
                    record.direction == .download ? "Show in Finder" : "Show Source in Finder",
                    action: onReveal
                )
            }
            if record.canRetry {
                Button(record.status == .cancelled ? "Resume" : "Retry", action: onRetry)
            }
            if let path = record.destinationURL?.path {
                Button("Copy Local Path") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(path, forType: .string)
                }
            }
            if let remote = record.remotePath {
                Button("Copy Device Path") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(remote, forType: .string)
                }
            }
        }
    }

    private var statusLabel: String {
        switch record.status {
        case .completed: return String(localized: "Completed")
        case .failed: return String(localized: "Failed")
        case .cancelled: return String(localized: "Paused")
        }
    }

    private var statusColor: Color {
        switch record.status {
        case .completed: return .secondary
        case .failed: return .red
        case .cancelled: return .orange
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch record.status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color.red)
        case .cancelled:
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(Color.orange)
        }
    }
}
