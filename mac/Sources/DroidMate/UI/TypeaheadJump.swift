import Foundation

/// Finder-style type-ahead jump for file lists (prefix match + same-key cycle).
enum TypeaheadJump {
    /// Clears after this idle interval (Finder is ~0.8–1s).
    static let idleClearSeconds: Double = 0.85

    /// Apply one typed character. Mutates `buffer` and returns the entry id to select, if any.
    /// - Parameter anchorID: preferred “current” row (last pointer / grid anchor), not `Set.first`.
    static func apply(
        character: Character,
        buffer: inout String,
        entries: [DirEntry],
        currentSelection: Set<DirEntry.ID>,
        anchorID: DirEntry.ID? = nil
    ) -> DirEntry.ID? {
        guard !entries.isEmpty else { return nil }
        let lower = String(character).lowercased()
        guard lower.count == 1,
              let c = lower.first,
              c.isLetter || c.isNumber || c == "." || c == "_" || c == "-" else {
            return nil
        }
        let ch = String(c)

        // Same letter again while buffer is that single letter → cycle matches.
        let cycling = buffer.lowercased() == ch
        if !cycling {
            buffer += ch
        }
        var prefix = buffer.lowercased()

        var matches = entries.filter { $0.name.lowercased().hasPrefix(prefix) }
        if matches.isEmpty {
            // Extended prefix failed — restart with this character alone (never cycle on restart).
            if prefix.count > 1 {
                buffer = ch
                prefix = ch
                matches = entries.filter { $0.name.lowercased().hasPrefix(prefix) }
                guard !matches.isEmpty else { return nil }
                return firstMatch(prefix: prefix, entries: entries, matches: matches, anchorID: anchorID, selection: currentSelection)
            }
            return nil
        }

        if cycling {
            let current = anchorID ?? currentSelection.first
            if let current, let idx = matches.firstIndex(where: { $0.id == current }) {
                return matches[(idx + 1) % matches.count].id
            }
        }

        return firstMatch(
            prefix: prefix,
            entries: entries,
            matches: matches,
            anchorID: anchorID,
            selection: currentSelection
        )
    }

    private static func firstMatch(
        prefix: String,
        entries: [DirEntry],
        matches: [DirEntry],
        anchorID: DirEntry.ID?,
        selection: Set<DirEntry.ID>
    ) -> DirEntry.ID? {
        let current = anchorID ?? selection.first
        if let current, let curIdx = entries.firstIndex(where: { $0.id == current }) {
            if let after = entries[curIdx...].first(where: { $0.name.lowercased().hasPrefix(prefix) }) {
                return after.id
            }
        }
        return matches.first?.id
    }
}
