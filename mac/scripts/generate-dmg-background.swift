#!/usr/bin/env swift
// Generates the Finder DMG window background (720×440 pixels).
// Finder maps background pixels 1:1 to window content points — keep 1× size.
//
// Usage:
//   swift scripts/generate-dmg-background.swift /path/to/dmg-background.png [icon.png]
//
// Icon drop-zone centers match build-dmg.sh AppleScript positions:
//   App @ {180, 205} · Applications @ {540, 205}

import AppKit
import Foundation

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "dmg-background.png"
let iconPath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : nil

let w = 720
let h = 440

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: w,
    pixelsHigh: h,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("bitmap alloc failed\n", stderr)
    exit(1)
}

rep.size = NSSize(width: w, height: h)
NSGraphicsContext.saveGraphicsState()
guard let gc = NSGraphicsContext(bitmapImageRep: rep) else {
    fputs("graphics context failed\n", stderr)
    exit(1)
}
NSGraphicsContext.current = gc
gc.imageInterpolation = .high
let ctx = gc.cgContext

// Finder {x, yFromTop} → Cocoa {x, h - yFromTop}
func cocoaY(_ finderY: CGFloat) -> CGFloat { CGFloat(h) - finderY }

// ── Base gradient ────────────────────────────────────────────────────
let baseColors = [
    NSColor(srgbRed: 0.08, green: 0.07, blue: 0.16, alpha: 1).cgColor,
    NSColor(srgbRed: 0.15, green: 0.10, blue: 0.34, alpha: 1).cgColor,
    NSColor(srgbRed: 0.10, green: 0.08, blue: 0.20, alpha: 1).cgColor,
]
if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                         colors: baseColors as CFArray,
                         locations: [0, 0.52, 1]) {
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 0, y: CGFloat(h)),
                           end: CGPoint(x: CGFloat(w), y: 0),
                           options: [])
}

func radialGlow(cx: CGFloat, cy: CGFloat, radius: CGFloat,
                r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
    let colors = [
        NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor,
        NSColor(srgbRed: r, green: g, blue: b, alpha: 0).cgColor,
    ]
    guard let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: colors as CFArray,
                                locations: [0, 1]) else { return }
    ctx.drawRadialGradient(glow,
                           startCenter: CGPoint(x: cx, y: cy),
                           startRadius: 0,
                           endCenter: CGPoint(x: cx, y: cy),
                           endRadius: radius,
                           options: [])
}

let appSlot = CGPoint(x: 180, y: cocoaY(205))
let appsSlot = CGPoint(x: 540, y: cocoaY(205))

radialGlow(cx: appSlot.x, cy: appSlot.y, radius: 130, r: 0.48, g: 0.28, b: 0.95, a: 0.30)
radialGlow(cx: appsSlot.x, cy: appsSlot.y, radius: 130, r: 0.36, g: 0.36, b: 0.96, a: 0.24)
radialGlow(cx: CGFloat(w) * 0.5, cy: cocoaY(70), radius: 180, r: 0.40, g: 0.25, b: 0.90, a: 0.14)

// Top hairline
NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06).setFill()
NSBezierPath(rect: NSRect(x: 0, y: CGFloat(h) - 1, width: CGFloat(w), height: 1)).fill()

// ── Drop-zone rings (under icons) ────────────────────────────────────
func drawSlotRing(center: CGPoint, radius: CGFloat) {
    let path = NSBezierPath(ovalIn: NSRect(x: center.x - radius,
                                           y: center.y - radius,
                                           width: radius * 2,
                                           height: radius * 2))
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07).setFill()
    path.fill()
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18).setStroke()
    path.lineWidth = 1.25
    path.stroke()
}

drawSlotRing(center: appSlot, radius: 58)
drawSlotRing(center: appsSlot, radius: 58)

// Connecting dashed arrow
let arrowY = appSlot.y
let arrow = NSBezierPath()
arrow.move(to: CGPoint(x: appSlot.x + 74, y: arrowY))
arrow.line(to: CGPoint(x: appsSlot.x - 80, y: arrowY))
var dashes: [CGFloat] = [5, 5]
arrow.setLineDash(&dashes, count: 2, phase: 0)
NSColor(srgbRed: 0.80, green: 0.74, blue: 1.0, alpha: 0.45).setStroke()
arrow.lineWidth = 2
arrow.lineCapStyle = .round
arrow.stroke()

let tipX = appsSlot.x - 76
let head = NSBezierPath()
head.move(to: CGPoint(x: tipX + 11, y: arrowY))
head.line(to: CGPoint(x: tipX - 1, y: arrowY + 7))
head.line(to: CGPoint(x: tipX - 1, y: arrowY - 7))
head.close()
NSColor(srgbRed: 0.80, green: 0.74, blue: 1.0, alpha: 0.52).setFill()
head.fill()

// ── Brand mark (top center) ──────────────────────────────────────────
func loadBrandIcon() -> NSImage? {
    var candidates: [String] = []
    if let iconPath { candidates.append(iconPath) }
    candidates += [
        "Sources/DroidMate/Resources/Brand/AppIcon.png",
        "Resources/Brand/AppIcon.png",
        "build/DroidMate.app/Contents/Resources/Brand/AppIcon.png",
        "build/DroidMate.app/Contents/Resources/AppIcon.png",
    ]
    let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let roots = [
        FileManager.default.currentDirectoryPath,
        scriptURL.path,
        scriptURL.deletingLastPathComponent().path,
    ]
    for rel in candidates {
        if rel.hasPrefix("/"), FileManager.default.fileExists(atPath: rel),
           let img = NSImage(contentsOfFile: rel) {
            return img
        }
        for root in roots {
            let p = (root as NSString).appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: p), let img = NSImage(contentsOfFile: p) {
                return img
            }
        }
    }
    return nil
}

let markSize: CGFloat = 52
let markCenterY = cocoaY(52)
let markRect = NSRect(x: (CGFloat(w) - markSize) / 2,
                      y: markCenterY - markSize / 2,
                      width: markSize, height: markSize)

ctx.saveGState()
let shadow = NSBezierPath(ovalIn: markRect.insetBy(dx: -5, dy: -5))
NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28).setFill()
shadow.fill()
if let brand = loadBrandIcon() {
    let clip = NSBezierPath(roundedRect: markRect, xRadius: markSize * 0.22, yRadius: markSize * 0.22)
    clip.addClip()
    brand.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 1.0)
} else {
    NSColor(srgbRed: 0.35, green: 0.25, blue: 0.85, alpha: 0.95).setFill()
    NSBezierPath(roundedRect: markRect, xRadius: markSize * 0.22, yRadius: markSize * 0.22).fill()
}
ctx.restoreGState()

// Title
let title = "DroidMate" as NSString
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
    .foregroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95),
]
let titleSize = title.size(withAttributes: titleAttrs)
let titleTop = cocoaY(96)
title.draw(at: CGPoint(x: (CGFloat(w) - titleSize.width) / 2,
                       y: titleTop - titleSize.height),
           withAttributes: titleAttrs)

// Subtitle
let sub = "Drag to Applications to install  ·  拖到应用程序即可安装" as NSString
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
    .foregroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.62),
]
let subSize = sub.size(withAttributes: subAttrs)
let subTop = cocoaY(134)
sub.draw(at: CGPoint(x: (CGFloat(w) - subSize.width) / 2,
                     y: subTop - subSize.height),
         withAttributes: subAttrs)

// Footer
let foot = "First open: right-click → Open    ·    首次打开：右键 → 打开" as NSString
let footAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
    .foregroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.50),
]
let footSize = foot.size(withAttributes: footAttrs)
foot.draw(at: CGPoint(x: (CGFloat(w) - footSize.width) / 2, y: 24),
          withAttributes: footAttrs)

NSColor(srgbRed: 0.55, green: 0.42, blue: 0.95, alpha: 0.40).setFill()
NSBezierPath(roundedRect: NSRect(x: (CGFloat(w) - 48) / 2, y: 14, width: 48, height: 2),
             xRadius: 1, yRadius: 1).fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("png encode failed\n", stderr)
    exit(1)
}
let url = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
do {
    try png.write(to: url)
    fputs("wrote \(outPath) (\(w)×\(h))\n", stderr)
} catch {
    fputs("write failed: \(error)\n", stderr)
    exit(1)
}
