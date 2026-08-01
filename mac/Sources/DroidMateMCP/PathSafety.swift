import Foundation

/// Path / package guards shared by MCP tool dispatch (unit-tested).
enum PathSafety {
    struct ValidationError: LocalizedError {
        let errorDescription: String?
    }

    /// Single-quote for adb shell so spaces / metacharacters stay literal.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isSafePackage(_ pkg: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._"))
        return !pkg.isEmpty && pkg.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Returns the normalized absolute path. `allowRoots: false` blocks catastrophic targets.
    static func validateDevicePath(_ path: String, allowRoots: Bool) throws -> String {
        guard !path.isEmpty else { throw ValidationError(errorDescription: "path is empty") }
        guard path.hasPrefix("/") else {
            throw ValidationError(errorDescription: "path must be absolute (start with /)")
        }
        guard !path.contains("\0") else {
            throw ValidationError(errorDescription: "path contains null byte")
        }
        guard !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ValidationError(errorDescription: "path contains control character")
        }

        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else {
                    throw ValidationError(errorDescription: "path escapes device root")
                }
                components.removeLast()
            default:
                components.append(component)
            }
        }
        let normalized = components.isEmpty ? "/" : "/" + components.joined(separator: "/")

        let roots: Set<String> = [
            "/", "/sdcard", "/storage", "/storage/emulated", "/storage/emulated/0",
            "/data", "/data/local", "/system", "/vendor",
        ]
        if !allowRoots && roots.contains(normalized) {
            throw ValidationError(errorDescription: "refusing to operate on protected root path: \(normalized)")
        }
        if !allowRoots {
            let destructivePrefixes = [
                "/sdcard/",
                "/storage/emulated/0/",
                "/storage/self/primary/",
                "/data/local/tmp/",
            ]
            guard destructivePrefixes.contains(where: normalized.hasPrefix) else {
                throw ValidationError(
                    errorDescription: "destructive paths are limited to shared storage or /data/local/tmp"
                )
            }
        }
        return normalized
    }

    /// Re-check the device's canonical path so an allowed lexical prefix
    /// cannot escape through an intermediate symlink.
    static func validateDestructiveResolution(requested: String, resolved: String) throws -> String {
        let normalized = try validateDevicePath(requested, allowRoots: false)
        _ = try validateDevicePath(resolved, allowRoots: false)
        return normalized
    }
}
