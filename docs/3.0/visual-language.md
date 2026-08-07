# 3.0 — Visual language

> **Status:** locked  
> **Source tickets:** [wayfinder/tickets/02-visual-design-language.md](../../wayfinder/tickets/02-visual-design-language.md)  
> **Platform research:** [wayfinder/research/05-macos-design-motion.md](../../wayfinder/research/05-macos-design-motion.md)  
> **Baseline craft:** `mac/Sources/DroidMate/UI/DesignSystem.swift` (0.2.x soft accent wash)  
> **Directional prototype:** [wayfinder/prototypes/shell-3.0](../../wayfinder/prototypes/shell-3.0/) (ticket 10 — feel anchor, not pixel contract)

## Decisions

1. **Stance = Hybrid** — system materials, type, and controls; product-specific density, selection language, empty states, file-browser chrome, and icon semantics. Not brand-forward skin; not “accent only” pure system with zero craft.
2. **Two material layers (hard rule)** — Liquid Glass on **navigation chrome only**; **standard materials** in content. No content-layer glass slabs.
3. **Appearance** — Light, Dark, and Follow System; default Follow System.
4. **Accent** — system accent color only (no fixed product override as default).
5. **Selection** — evolve unified soft accent wash (list + grid); do not default to stock solid list selection.
6. **Type** — system fonts / text styles only; utility density allowed for file browser.
7. **Icons** — SF Symbols first; no full custom multicolor icon system.

## Principles

### North-star fit

Visual language serves **feel native**. Anything that reads as a themed Electron shell, or that fights Liquid Glass / standard content materials, is out of language.

### Brand expression (allowed)

| Channel | Guidance |
|---------|----------|
| App icon / mark | Primary brand vessel |
| Empty / error / onboarding illustrations | Quiet, Mac-like; prefer SF + short copy over mascot spam |
| Density & spacing tokens | Product utility craft (document in design system code) |
| Selection wash | Soft accent fill + stroke (see below) |
| File browser chrome | Path bar, grids, inspector — native controls, product layout |

### Brand expression (disallowed as defaults)

- Fixed brand tint replacing system accent
- Custom font families
- Content regions filled with glass materials for “premium” effect
- Full custom colorful icon packs for chrome
- Hand-drawn sidebar/toolbar materials competing with system glass

### Materials

```
Window
└── Navigation chrome (system Liquid Glass)
    ├── sidebar, toolbar, menus
└── Content (standard materials / opaque hierarchical fills)
    ├── file list / grid
    ├── transfer UI
    └── status / inline banners
```

Implementers: prefer stock `NavigationSplitView` + `.toolbar` so glass is free; **remove** custom bar backgrounds that block system materials ([Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)).

### Selection chrome (contract)

- **Same language** for list rows and grid tiles.
- Soft accent wash derived from `Color.accentColor` with dark/light-tuned opacity (0.2.x pattern in `DesignSystem` / selection helpers — evolve, don’t fork per surface).
- Keyboard focus ring remains system-visible; wash must not hide focus.
- Verify **Increase Contrast** and **Reduce Transparency**.

### Appearance modes

| Mode | Support |
|------|---------|
| Follow System | Default |
| Light | Explicit override in Settings |
| Dark | Explicit override in Settings |

Surfaces use adaptive semantic colors (`primary`, `secondary`, separators, fills) — not hard-coded light-only palettes.

### Typography & density

- Text: system styles (body, callout, caption, headline as appropriate).
- File browser may use **slightly tighter** row height / grid padding than stock Mail-like comfort, as long as click targets stay usable and Reduce Motion / a11y paths aren’t compromised.
- Sidebar icon size: prefer system sidebar behavior.

### Iconography

- Toolbars, menus, sidebar destinations: **SF Symbols**, template mode.
- File kind icons: SF where suitable; custom glyphs only if monochrome/template-compatible and visually quiet.

### Accessibility & system settings (visual)

Must remain coherent under:

- Increase Contrast  
- Reduce Transparency  
- Preferred accent color  
- Appearance (light/dark)  
- (Motion covered in motion-language chapter)

### Out of language (defer)

- Pixel mock packs as contract (prototype ticket 10 is directional only)
- Marketing illustration systems beyond empty states
- Non-Mac platform themes

## Open for later chapters (not blocking this lock)

- Exact spacing token table → lives in implementation design-system code; this chapter sets rules, not every point value.
- Shell layout structure → `shell-and-ia.md` (ticket 06).
- Motion curves → `motion-language.md` (ticket 09).
