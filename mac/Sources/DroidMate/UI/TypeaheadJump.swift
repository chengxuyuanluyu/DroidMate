import Foundation

/// Finder-style type-ahead jump for file lists (prefix match + same-key cycle).
enum TypeaheadJump {
    /// Clears after this idle interval (Finder is ~0.8–1s).
    static let idleClearSeconds: Double = 0.85

    /// Apply one typed character. Mutates `buffer` and returns the entry id to select, if any.
    static func apply(
        character: Character,
        buffer: inout String,
        entries: [DirEntry],
        currentSelection: Set<DirEntry.ID>
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
        let prefix = buffer.lowercased()

        let matches = entries.filter { $0.name.lowercased().hasPrefix(prefix) }
        if matches.isEmpty {
            // Extended prefix failed — restart with this character alone.
            if prefix.count > 1 {
                buffer = ch
                return apply(
                    character: character,
                    buffer: &buffer,
                    entries: entries,
                    currentSelection: currentSelection
                )
            }
            return nil
        }

        if cycling, let current = currentSelection.first,
           let idx = matches.firstIndex(where: { $0.id == current }) {
            return matches[(idx + 1) % matches.count].id
        }

        // First match at/after current row, else first overall match.
        if let current = currentSelection.first,
           let curIdx = entries.firstIndex(where: { $0.id == current }) {
            if let after = entries[curIdx...].first(where: { $0.name.lowercased().hasPrefix(prefix) }) {
                return after.id
            }
        }
        return matches[0].id
    }
}
