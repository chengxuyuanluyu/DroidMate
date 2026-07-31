import AppKit
import Foundation

/// Finder-style name conflict resolution for upload / download targets.
enum NameConflict {
    enum Choice {
        /// Overwrite the existing item.
        case replace
        /// Use a unique sibling name (`photo (1).jpg`).
        case keepBoth
        /// Abort the whole operation (or skip one item when used per-file).
        case cancel
    }

    /// Present Replace / Keep Both / Cancel. Must run on the main actor (NSAlert).
    @MainActor
    static func choose(for label: String) -> Choice {
        let alert = NSAlert()
        alert.messageText = String(localized: "\"\(label)\" already exists.")
        alert.informativeText = String(localized: "Do you want to replace it, or keep both with a new name?")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Replace"))
        alert.addButton(withTitle: String(localized: "Keep Both"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .replace
        case .alertSecondButtonReturn: return .keepBoth
        default: return .cancel
        }
    }

    /// `photo.jpg` + existing → `photo (1).jpg`, `photo (2).jpg`, …
    static func uniqueName(_ name: String, among existing: Set<String>) -> String {
        if !existing.contains(name) { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ext.isEmpty ? name : ns.deletingPathExtension
        var i = 1
        while true {
            let candidate: String
            if ext.isEmpty {
                candidate = "\(base) (\(i))"
            } else {
                candidate = "\(base) (\(i)).\(ext)"
            }
            if !existing.contains(candidate) { return candidate }
            i += 1
            if i > 10_000 { return "\(base)-\(UUID().uuidString.prefix(8)).\(ext)" }
        }
    }

    /// Finder-style duplicate name: `photo copy.jpg`, then `photo copy 2.jpg`, …
    static func copyName(_ name: String, among existing: Set<String>) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ext.isEmpty ? name : ns.deletingPathExtension
        func make(_ suffix: String) -> String {
            ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
        }
        let first = make(" copy")
        if !existing.contains(first) { return first }
        var i = 2
        while true {
            let candidate = make(" copy \(i)")
            if !existing.contains(candidate) { return candidate }
            i += 1
            if i > 10_000 { return make(" copy \(UUID().uuidString.prefix(8))") }
        }
    }

    /// Local folder: names that already exist as files or directories.
    static func existingNames(in directory: URL) -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(contents)
    }
}
