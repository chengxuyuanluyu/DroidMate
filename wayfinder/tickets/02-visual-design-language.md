# Ticket 02 — Visual design language stance

`wayfinder:grilling` · **status: closed (resolved)** · `blocked-by:` none
· **claimed:** resolved this session

## Question

What is DroidMate 3.0’s **visual design language** relative to macOS system UI
and brand?

Poles:

- **System-native** — lean entirely on macOS 15+ materials, controls, and HIG;
  brand is mark + accent only.
- **Brand-forward** — distinctive custom chrome/surfaces (risk: “Electron skin”
  or fighting the platform).
- **Hybrid (recommended default to stress-test)** — system materials, type, and
  controls; DroidMate-specific **density, accent, iconography, empty states**,
  and file-browser chrome that still read as native.

Also decide:

1. Light / dark / auto requirements for 3.0.
2. Whether accent remains system accent vs fixed product color.
3. How far list/grid selection chrome may diverge from stock `List`/`Table`
   (0.2.x already uses soft accent wash — keep, evolve, or reset).

Output of resolution: principles short enough to open the Visual Language
chapter of the 3.0 package (exact path per ticket 01).

## Write target

Resolution lands in the matching chapter under `docs/3.0/` (see package README). Shape: ticket 01.

## Resolution

**Locked 2026-08-07** (user: all recommendations).

### Stance

**Hybrid — system-native craft with quiet product specificity.**

- Ride **system chrome** (Liquid Glass navigation layer via standard split view /
  toolbar / menus), system controls, and system type.
- Product identity lives in **density, selection language, empty states,
  file-browser chrome, and icon semantics** — not a custom skin.

### Hard material rule (two layers)

| Layer | Material |
|-------|----------|
| **Navigation / functional chrome** | System **Liquid Glass** (sidebar, toolbar, menus); do not hand-draw competing glass |
| **Content** | **Standard materials only** (lists, grids, transfer rows, status). **No** content-layer Liquid Glass slabs |

Aligned with [research/05-macos-design-motion.md](../research/05-macos-design-motion.md).

### Appearance

- **Light + Dark + Follow System**; default **Follow System**.

### Accent

- **System accent** (`Color.accentColor` / user System Settings).
- Brand is App Icon + empty-state craft + density — **not** a fixed product tint
  that overrides the system.

### Selection chrome

- **Evolve 0.2 soft accent wash** as the default for **both** list and grid:
  soft fill + subtle stroke; unified language.
- **Do not** regress to stock solid system list selection as the product default.
- Must remain legible under Increase Contrast / Reduce Transparency.

### Type & density

- **San Francisco / system text styles only** — no custom font family.
- Utility **slightly denser** file browser metrics allowed; still respect system
  sidebar icon size and accessibility text sizing where applicable.

### Icons

- **SF Symbols first** for toolbars, sidebars, menus (template rendering).
- File-type glyphs may be light custom marks but must match SF weight/template
  behavior — **no** full custom multicolor icon suite as the system language.

### Package

Principles written to [`docs/3.0/visual-language.md`](../../docs/3.0/visual-language.md)
with status **`locked`**. Unblocks motion language (ticket 09) and shell/IA
(ticket 06) on the visual axis.
