import Foundation

/// Path / package guards shared by MCP tool dispatch (unit-tested).
enum PathSafety {
    /// Single-quote for adb shell so spaces / metacharacters stay literal.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isSafePackage(_ pkg: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._"))
        return !pkg.isEmpty && pkg.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Absolute paths only. `allowRoots: false` blocks catastrophic rm -rf targets.
    static func validateDevicePath(_ path: String, allowRoots: Bool) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "path is empty" }
        guard trimmed.hasPrefix("/") else { return "path must be absolute (start with /)" }
        guard !trimmed.contains("\0") else { return "path contains null byte" }
        let normalized: String = {
            if trimmed.count > 1 && trimmed.hasSuffix("/") {
                return String(trimmed.dropLast())
            }
            return trimmed
        }()
        let roots: Set<String> = [
            "/", "/sdcard", "/storage", "/storage/emulated", "/storage/emulated/0",
            "/data", "/data/local", "/system", "/vendor",
        ]
        if !allowRoots && roots.contains(normalized) {
            return "refusing to operate on protected root path: \(normalized)"
        }
        return nil
    }
}
