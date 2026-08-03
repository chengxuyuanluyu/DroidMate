import Foundation

/// Per-device persistence for the transfer history, so completed transfers
/// survive app relaunch. Stored as JSON under Application Support, keyed by
/// device serial (colons are common in wireless serials and are escaped).
enum TransferHistoryStore {
    static func url(for serial: String) -> URL {
        let safe = serial.replacingOccurrences(of: ":", with: "_")
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DroidMate/TransferHistory/\(safe).json")
    }

    /// Returns the persisted records, or an empty list when missing/corrupt.
    /// A corrupt file is moved aside (`.corrupt`) instead of left in place —
    /// a later save would otherwise silently overwrite the only copy of the
    /// history with an empty list.
    static func load(serial: String) -> [TransferRecord] {
        let url = url(for: serial)
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let records = try? JSONDecoder().decode([TransferRecord].self, from: data) {
            return records
        }
        try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
        return []
    }

    /// Best-effort write; failures degrade silently to in-memory-only history.
    /// `.atomic` so a crash mid-write can never leave truncated JSON behind.
    static func save(serial: String, records: [TransferRecord]) {
        let url = url(for: serial)
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
