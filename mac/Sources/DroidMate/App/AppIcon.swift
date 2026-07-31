import AppKit

/// DroidMate brand app icon.
///
/// Prefer the designed brand asset at `Resources/Brand/AppIcon.png` (concept B
/// full-bleed: solid D + phone + folders on indigo–violet glass filling the
/// square; macOS applies the continuous-corner mask — do not nest a squircle
/// inside a square). Falls back to procedural draw if the asset is missing.
enum AppIcon {
    /// Dock icon: prefer `AppIcon.icns` from the .app bundle so macOS applies
    /// the continuous-corner mask (same as every other Dock app).
    /// Never assign a raw PNG to `applicationIconImage` when an icns exists —
    /// that path draws a hard square and looks broken next to real app icons.
    @MainActor static func apply() {
        if bundleHasICNS() {
            return
        }
        // Dev / bare binary fallback only.
        if let branded = loadBrandedNSImage(preferredSize: 512) {
            NSApp.applicationIconImage = branded
        } else {
            NSApp.applicationIconImage = render(size: 512)
        }
    }

    private static func bundleHasICNS() -> Bool {
        if Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil {
            return true
        }
        guard let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String
        else { return false }
        let base = (name as NSString).deletingPathExtension
        if base != name,
           Bundle.main.url(forResource: base, withExtension: "icns") != nil {
            return true
        }
        return Bundle.main.url(forResource: name, withExtension: "icns") != nil
            || Bundle.main.url(forResource: name, withExtension: nil) != nil
    }

    /// CLI: `DroidMate --export-icon /path/to/icon-1024.png` then exit.
    /// Used by `scripts/build-dmg.sh` to produce AppIcon.icns for the bundle.
    static func handleCLIIfNeeded() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--export-icon"),
              args.count > idx + 1 else { return }
        let dest = URL(fileURLWithPath: args[idx + 1])
        do {
            try writePNG(size: 1024, to: dest)
            fputs("exported icon → \(dest.path)\n", stderr)
            exit(0)
        } catch {
            fputs("export icon failed: \(error)\n", stderr)
            exit(1)
        }
    }

    static func writePNG(size: Int, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Prefer shipping the designed brand file at native resolution.
        if let brandedURL = locateBrandedPNG(),
           let data = try? Data(contentsOf: brandedURL) {
            if size == 1024 {
                try data.write(to: url)
                return
            }
            // Scale via NSImage when a non-1024 export is requested.
            if let img = NSImage(data: data) {
                let scaled = resize(img, to: size)
                try writeNSImagePNG(scaled, to: url)
                return
            }
        }
        let image = render(size: size)
        try writeNSImagePNG(image, to: url)
    }

    /// Brand mark for SwiftUI (onboarding / about) — prefers designed asset.
    static func brandNSImage(size: CGFloat = 256) -> NSImage {
        if let img = loadBrandedNSImage(preferredSize: Int(size)) {
            return img
        }
        return render(size: Int(size))
    }

    // MARK: - Asset loading

    private static func locateBrandedPNG() -> URL? {
        let names = ["AppIcon", "AppIcon-1024"]
        // Packaged .app (Resources/Brand) first; never touch Bundle.module (traps if missing).
        for name in names {
            if let u = ResourceBundle.url(forResource: name, withExtension: "png", subdirectory: "Brand") {
                return u
            }
            if let u = ResourceBundle.url(forResource: name, withExtension: "png") {
                return u
            }
        }
        return nil
    }

    private static func loadBrandedNSImage(preferredSize: Int) -> NSImage? {
        guard let url = locateBrandedPNG(),
              let img = NSImage(contentsOf: url) else { return nil }
        if preferredSize > 0 {
            return resize(img, to: preferredSize)
        }
        return img
    }

    private static func resize(_ image: NSImage, to size: Int) -> NSImage {
        let s = CGFloat(size)
        let out = NSImage(size: NSSize(width: s, height: s))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: s, height: s),
                   from: .zero,
                   operation: .copy,
                   fraction: 1)
        out.unlockFocus()
        return out
    }

    private static func writeNSImagePNG(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "AppIcon", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode PNG"
            ])
        }
        try png.write(to: url)
    }

    // MARK: - Procedural fallback (legacy, kept for resilience)

    private static func render(size: Int) -> NSImage {
        let s = CGFloat(size)
        let image = NSImage(size: NSSize(width: s, height: s))
        image.lockFocus()
        defer { image.unlockFocus() }

        let ctx = NSGraphicsContext.current!.cgContext
        // Full-bleed square — macOS (or Dock) applies the continuous corner mask.
        // Do not pre-clip to a squircle; that causes nested / square-looking icons.

        // Brand gradient: deep indigo → violet (matches designed logo)
        let gradColors = [
            NSColor(srgbRed: 0.12, green: 0.12, blue: 0.42, alpha: 1).cgColor,
            NSColor(srgbRed: 0.28, green: 0.18, blue: 0.72, alpha: 1).cgColor,
            NSColor(srgbRed: 0.48, green: 0.22, blue: 0.88, alpha: 1).cgColor,
        ]
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: gradColors as CFArray,
                              locations: [0.0, 0.55, 1.0])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s),
                               end: CGPoint(x: s, y: 0), options: [])

        // Soft specular
        let glow = [
            NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22).cgColor,
            NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0).cgColor,
        ]
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: glow as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(g,
                                   startCenter: CGPoint(x: s * 0.32, y: s * 0.72),
                                   startRadius: 0,
                                   endCenter: CGPoint(x: s * 0.32, y: s * 0.72),
                                   endRadius: s * 0.55,
                                   options: [])
        }

        NSColor.white.setStroke()
        NSColor.white.setFill()
        let lineW = max(s * 0.028, 1.5)

        // Monogram “D” as phone body + curve (fallback geometric brand)
        let left = s * 0.26
        let top = s * 0.22
        let phoneW = s * 0.28
        let phoneH = s * 0.56
        let phone = NSBezierPath(roundedRect: CGRect(x: left, y: top, width: phoneW, height: phoneH),
                                 xRadius: phoneW * 0.18, yRadius: phoneW * 0.18)
        phone.lineWidth = lineW
        phone.stroke()

        // Notch
        let notch = NSBezierPath(roundedRect: CGRect(x: left + phoneW * 0.28, y: top + phoneH * 0.06,
                                                     width: phoneW * 0.44, height: s * 0.018),
                                 xRadius: s * 0.008, yRadius: s * 0.008)
        notch.fill()

        // Home bar
        let home = NSBezierPath(roundedRect: CGRect(x: left + phoneW * 0.30, y: top + phoneH * 0.90,
                                                    width: phoneW * 0.40, height: s * 0.014),
                                xRadius: s * 0.006, yRadius: s * 0.006)
        home.fill()

        // D curve on the right
        let curve = NSBezierPath()
        let midY = top + phoneH * 0.5
        curve.move(to: CGPoint(x: left + phoneW * 0.55, y: top + phoneH * 0.12))
        curve.appendArc(withCenter: CGPoint(x: left + phoneW * 0.55, y: midY),
                        radius: phoneH * 0.38,
                        startAngle: 90, endAngle: -90, clockwise: true)
        curve.lineWidth = lineW
        curve.lineCapStyle = .round
        curve.stroke()

        // 2×2 folder grid inside D
        let gOrigin = CGPoint(x: left + phoneW * 0.42, y: midY - s * 0.09)
        let cell = s * 0.07
        let gap = s * 0.025
        for r in 0..<2 {
            for c in 0..<2 {
                let rect = CGRect(x: gOrigin.x + CGFloat(c) * (cell + gap),
                                  y: gOrigin.y + CGFloat(r) * (cell + gap),
                                  width: cell, height: cell * 0.75)
                let folder = NSBezierPath(roundedRect: rect, xRadius: cell * 0.12, yRadius: cell * 0.12)
                folder.lineWidth = lineW * 0.55
                folder.stroke()
            }
        }

        return image
    }
}
