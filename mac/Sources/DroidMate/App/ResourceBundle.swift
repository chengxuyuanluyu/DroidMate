import Foundation

/// Resource lookup that is safe in both `swift run` and packaged `.app` builds.
///
/// SPM’s generated `Bundle.module` **fatalErrors** when `DroidMate_DroidMate.bundle`
/// is not next to the executable. Our DMG packaging flattens resources into
/// `Contents/Resources/` and does not ship that nested bundle — so any launch-time
/// `Bundle.module` access crashes the app before the first window appears.
enum ResourceBundle {
    /// Always available: the main application bundle.
    static var main: Bundle { Bundle.main }

    /// SPM resource bundle when present (dev `swift run` / unflattened layouts).
    /// Returns `nil` instead of trapping when the bundle is missing.
    static var spm: Bundle? {
        #if SWIFT_PACKAGE
        let name = "DroidMate_DroidMate"
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("\(name).bundle"))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("\(name).bundle"))
        // `swift run` places the resource bundle next to the product binary.
        candidates.append(
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(name).bundle")
        )
        // Nested Contents/MacOS → sibling Resources
        candidates.append(
            Bundle.main.bundleURL
                .deletingLastPathComponent() // MacOS
                .deletingLastPathComponent() // Contents
                .appendingPathComponent("Resources/\(name).bundle")
        )
        for url in candidates {
            if let b = Bundle(url: url) { return b }
        }
        #endif
        return nil
    }

    /// Resolve a named resource: main bundle first (packaged app), then SPM bundle.
    static func url(
        forResource name: String,
        withExtension ext: String?,
        subdirectory sub: String? = nil
    ) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: sub) {
            return u
        }
        if let u = Bundle.main.url(forResource: name, withExtension: ext) {
            return u
        }
        if let spm {
            if let sub, let u = spm.url(forResource: name, withExtension: ext, subdirectory: sub) {
                return u
            }
            if let u = spm.url(forResource: name, withExtension: ext) {
                return u
            }
        }
        return nil
    }
}
