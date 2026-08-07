import SwiftUI

/// PROTOTYPE motion tokens — mirrors docs/3.0/motion-language.md (DM.Motion.*).
enum ProtoMotion {
    static func meso(reduceMotion: Bool) -> Animation? {
        if reduceMotion { return .easeOut(duration: 0.15) }
        return .snappy(duration: 0.28)
    }

    static func macro(reduceMotion: Bool) -> Animation? {
        if reduceMotion { return .easeOut(duration: 0.12) }
        return .smooth(duration: 0.42)
    }

    /// Selection / progress — intentionally nil (P1 / no spring).
    static let none: Animation? = nil
}
